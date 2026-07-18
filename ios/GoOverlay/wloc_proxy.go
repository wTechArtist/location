package libbox

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/http2"
)

const maxWlocBodySize = 32 << 20

var allowedWlocHosts = map[string]struct{}{
	"gs-loc.apple.com":    {},
	"gs-loc-cn.apple.com": {},
}

// WlocResponsePatcher is implemented by the Packet Tunnel in Swift. Keeping the
// binary transformation on the Swift side lets it use the same tested patcher and
// App Group target state as the main application.
type WlocResponsePatcher interface {
	PatchResponse(body []byte) ([]byte, error)
	WriteLog(message string)
}

type WlocCA struct {
	certificateDER []byte
	privateKeyDER  []byte
}

func (c *WlocCA) CertificateDER() []byte { return append([]byte(nil), c.certificateDER...) }
func (c *WlocCA) PrivateKeyDER() []byte  { return append([]byte(nil), c.privateKeyDER...) }

func GenerateWlocCA() (*WlocCA, error) {
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate WLOC CA key: %w", err)
	}
	serial, err := randomSerial()
	if err != nil {
		return nil, err
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   "WLOC Device CA",
			Organization: []string{"WLOC Local Device"},
		},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.AddDate(5, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0,
	}
	certificateDER, err := x509.CreateCertificate(rand.Reader, template, template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return nil, fmt.Errorf("create WLOC CA: %w", err)
	}
	privateKeyDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return nil, fmt.Errorf("marshal WLOC CA key: %w", err)
	}
	return &WlocCA{certificateDER: certificateDER, privateKeyDER: privateKeyDER}, nil
}

type WlocProxy struct {
	caCertificate *x509.Certificate
	caPrivateKey  *ecdsa.PrivateKey
	patcher       WlocResponsePatcher
	transport     *http.Transport

	access       sync.Mutex
	listener     net.Listener
	connections  map[net.Conn]struct{}
	certificates map[string]*tls.Certificate
	waitGroup    sync.WaitGroup
}

func NewWlocProxy(certificateDER []byte, privateKeyDER []byte, patcher WlocResponsePatcher) (*WlocProxy, error) {
	if patcher == nil {
		return nil, errors.New("WLOC response patcher is required")
	}
	certificate, err := x509.ParseCertificate(certificateDER)
	if err != nil {
		return nil, fmt.Errorf("parse WLOC CA certificate: %w", err)
	}
	if !certificate.IsCA {
		return nil, errors.New("WLOC certificate is not a CA")
	}
	parsedKey, err := x509.ParsePKCS8PrivateKey(privateKeyDER)
	if err != nil {
		return nil, fmt.Errorf("parse WLOC CA private key: %w", err)
	}
	privateKey, ok := parsedKey.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("WLOC CA private key must be ECDSA")
	}
	publicKey, ok := certificate.PublicKey.(*ecdsa.PublicKey)
	if !ok || !publicKey.Equal(privateKey.Public()) {
		return nil, errors.New("WLOC CA certificate and private key do not match")
	}
	return &WlocProxy{
		caCertificate: certificate,
		caPrivateKey:  privateKey,
		patcher:       patcher,
		connections:   make(map[net.Conn]struct{}),
		certificates:  make(map[string]*tls.Certificate),
		transport: &http.Transport{
			Proxy:               nil,
			ForceAttemptHTTP2:   true,
			DisableCompression:  true,
			MaxIdleConns:        4,
			IdleConnTimeout:     30 * time.Second,
			TLSHandshakeTimeout: 15 * time.Second,
			TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
		},
	}, nil
}

func (p *WlocProxy) Start() error {
	p.access.Lock()
	defer p.access.Unlock()
	if p.listener != nil {
		return nil
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return fmt.Errorf("listen WLOC proxy: %w", err)
	}
	p.listener = listener
	p.waitGroup.Add(1)
	go p.serve(listener)
	p.log(fmt.Sprintf("listening on 127.0.0.1:%d", listener.Addr().(*net.TCPAddr).Port))
	return nil
}

func (p *WlocProxy) Port() int32 {
	p.access.Lock()
	defer p.access.Unlock()
	if p.listener == nil {
		return 0
	}
	return int32(p.listener.Addr().(*net.TCPAddr).Port)
}

func (p *WlocProxy) Close() error {
	p.access.Lock()
	listener := p.listener
	p.listener = nil
	connections := make([]net.Conn, 0, len(p.connections))
	for connection := range p.connections {
		connections = append(connections, connection)
	}
	p.access.Unlock()
	if listener == nil {
		return nil
	}
	err := listener.Close()
	for _, connection := range connections {
		_ = connection.Close()
	}
	p.transport.CloseIdleConnections()
	p.waitGroup.Wait()
	if err != nil && !errors.Is(err, net.ErrClosed) {
		return err
	}
	return nil
}

func (p *WlocProxy) serve(listener net.Listener) {
	defer p.waitGroup.Done()
	for {
		connection, err := listener.Accept()
		if err != nil {
			if !errors.Is(err, net.ErrClosed) {
				p.log("accept failed: " + err.Error())
			}
			return
		}
		p.access.Lock()
		if p.listener != listener {
			p.access.Unlock()
			_ = connection.Close()
			return
		}
		p.connections[connection] = struct{}{}
		p.waitGroup.Add(1)
		p.access.Unlock()
		go func() {
			defer func() {
				p.access.Lock()
				delete(p.connections, connection)
				p.access.Unlock()
				p.waitGroup.Done()
			}()
			p.handleConnection(connection)
		}()
	}
}

func (p *WlocProxy) handleConnection(connection net.Conn) {
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(60 * time.Second))
	reader := bufio.NewReaderSize(connection, 16*1024)
	request, err := http.ReadRequest(reader)
	if err != nil {
		p.log("read CONNECT failed: " + err.Error())
		return
	}
	if request.Body != nil {
		_ = request.Body.Close()
	}
	if request.Method != http.MethodConnect {
		writeProxyError(connection, http.StatusMethodNotAllowed, "CONNECT required")
		return
	}
	host := request.Host
	if parsedHost, port, splitErr := net.SplitHostPort(host); splitErr == nil {
		if port != "443" {
			writeProxyError(connection, http.StatusForbidden, "WLOC CONNECT port must be 443")
			return
		}
		host = parsedHost
	}
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if !isAllowedWlocHost(host) {
		writeProxyError(connection, http.StatusForbidden, "target is not a WLOC host")
		return
	}
	if _, err = io.WriteString(connection, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}

	buffered := &bufferedConnection{Conn: connection, reader: reader}
	tlsConnection := tls.Server(buffered, &tls.Config{
		MinVersion: tls.VersionTLS12,
		NextProtos: []string{"h2", "http/1.1"},
		GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
			serverName := strings.ToLower(strings.TrimSuffix(hello.ServerName, "."))
			if serverName == "" {
				serverName = host
			}
			if !isAllowedWlocHost(serverName) || serverName != host {
				return nil, fmt.Errorf("unexpected WLOC SNI %q", serverName)
			}
			return p.certificateForHost(serverName)
		},
	})
	if err = tlsConnection.Handshake(); err != nil {
		p.log("client TLS handshake failed: " + err.Error())
		return
	}
	_ = connection.SetDeadline(time.Time{})
	p.log("intercepted " + host + " via " + tlsConnection.ConnectionState().NegotiatedProtocol)

	if tlsConnection.ConnectionState().NegotiatedProtocol == "h2" {
		server := &http2.Server{}
		server.ServeConn(tlsConnection, &http2.ServeConnOpts{Handler: http.HandlerFunc(p.serveHTTP)})
		return
	}
	p.serveHTTP1(tlsConnection, host)
}

func (p *WlocProxy) serveHTTP1(connection net.Conn, host string) {
	reader := bufio.NewReaderSize(connection, 32*1024)
	for {
		request, err := http.ReadRequest(reader)
		if err != nil {
			if !errors.Is(err, io.EOF) {
				p.log("read HTTPS request failed: " + err.Error())
			}
			return
		}
		if request.Host == "" {
			request.Host = host
		}
		response, err := p.roundTrip(request)
		if err != nil {
			writeProxyError(connection, http.StatusBadGateway, err.Error())
			return
		}
		if err = response.Write(connection); err != nil {
			_ = response.Body.Close()
			return
		}
		_ = response.Body.Close()
		if request.Close || response.Close {
			return
		}
	}
}

func (p *WlocProxy) serveHTTP(writer http.ResponseWriter, request *http.Request) {
	response, err := p.roundTrip(request)
	if err != nil {
		http.Error(writer, err.Error(), http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	copyHeaders(writer.Header(), response.Header)
	writer.WriteHeader(response.StatusCode)
	_, _ = io.Copy(writer, response.Body)
}

func (p *WlocProxy) roundTrip(request *http.Request) (*http.Response, error) {
	host := strings.ToLower(strings.TrimSuffix(request.Host, "."))
	if parsedHost, _, err := net.SplitHostPort(host); err == nil {
		host = parsedHost
	}
	if !isAllowedWlocHost(host) {
		return nil, fmt.Errorf("unexpected HTTPS host %q", host)
	}
	upstreamRequest := request.Clone(context.Background())
	upstreamRequest.RequestURI = ""
	upstreamRequest.URL = cloneURL(request.URL)
	upstreamRequest.URL.Scheme = "https"
	upstreamRequest.URL.Host = request.Host
	upstreamRequest.Header = request.Header.Clone()
	removeHopByHopHeaders(upstreamRequest.Header)

	response, err := p.transport.RoundTrip(upstreamRequest)
	if err != nil {
		return nil, fmt.Errorf("WLOC upstream request: %w", err)
	}
	body, err := readResponseBody(response)
	if err != nil {
		_ = response.Body.Close()
		return nil, err
	}
	_ = response.Body.Close()
	patchedBody, err := p.patcher.PatchResponse(body)
	if err != nil {
		return nil, fmt.Errorf("patch WLOC response: %w", err)
	}
	response.Body = io.NopCloser(bytes.NewReader(patchedBody))
	response.ContentLength = int64(len(patchedBody))
	response.Header.Del("Content-Encoding")
	response.Header.Del("Transfer-Encoding")
	response.Header.Set("Content-Length", fmt.Sprint(len(patchedBody)))
	response.TransferEncoding = nil
	response.Uncompressed = true
	return response, nil
}

func readResponseBody(response *http.Response) ([]byte, error) {
	var reader io.Reader = response.Body
	contentEncoding := strings.TrimSpace(response.Header.Get("Content-Encoding"))
	if strings.EqualFold(contentEncoding, "gzip") {
		gzipReader, err := gzip.NewReader(response.Body)
		if err != nil {
			return nil, fmt.Errorf("decode WLOC gzip: %w", err)
		}
		defer gzipReader.Close()
		reader = gzipReader
	} else if contentEncoding != "" && !strings.EqualFold(contentEncoding, "identity") {
		return nil, fmt.Errorf("unsupported WLOC content encoding %q", contentEncoding)
	}
	limited := io.LimitReader(reader, maxWlocBodySize+1)
	body, err := io.ReadAll(limited)
	if err != nil {
		return nil, fmt.Errorf("read WLOC response: %w", err)
	}
	if len(body) > maxWlocBodySize {
		return nil, errors.New("WLOC response exceeds 32 MiB")
	}
	return body, nil
}

func (p *WlocProxy) certificateForHost(host string) (*tls.Certificate, error) {
	p.access.Lock()
	defer p.access.Unlock()
	if certificate := p.certificates[host]; certificate != nil {
		return certificate, nil
	}
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := randomSerial()
	if err != nil {
		return nil, err
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: host, Organization: []string{"WLOC Local Device"}},
		DNSNames:     []string{host},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.AddDate(0, 0, 30),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	certificateDER, err := x509.CreateCertificate(rand.Reader, template, p.caCertificate, &privateKey.PublicKey, p.caPrivateKey)
	if err != nil {
		return nil, err
	}
	privateKeyDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return nil, err
	}
	certificate, err := tls.X509KeyPair(
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificateDER}),
		pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateKeyDER}),
	)
	if err != nil {
		return nil, err
	}
	certificate.Certificate = append(certificate.Certificate, p.caCertificate.Raw)
	p.certificates[host] = &certificate
	return &certificate, nil
}

func randomSerial() (*big.Int, error) {
	limit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, limit)
	if err != nil {
		return nil, fmt.Errorf("generate certificate serial: %w", err)
	}
	return serial, nil
}

func isAllowedWlocHost(host string) bool {
	_, allowed := allowedWlocHosts[host]
	return allowed
}

func writeProxyError(writer io.Writer, status int, message string) {
	_, _ = fmt.Fprintf(writer, "HTTP/1.1 %d %s\r\nConnection: close\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n%s", status, http.StatusText(status), len(message), message)
}

func removeHopByHopHeaders(header http.Header) {
	for _, name := range []string{"Connection", "Proxy-Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization", "TE", "Trailer", "Transfer-Encoding", "Upgrade"} {
		header.Del(name)
	}
}

func copyHeaders(destination, source http.Header) {
	for name, values := range source {
		if name == "Connection" || name == "Transfer-Encoding" {
			continue
		}
		for _, value := range values {
			destination.Add(name, value)
		}
	}
}

func cloneURL(source *url.URL) *url.URL {
	if source == nil {
		return &url.URL{}
	}
	clone := *source
	return &clone
}

func (p *WlocProxy) log(message string) {
	p.patcher.WriteLog("[wloc-mitm] " + message)
}

type bufferedConnection struct {
	net.Conn
	reader *bufio.Reader
}

func (c *bufferedConnection) Read(buffer []byte) (int, error) { return c.reader.Read(buffer) }

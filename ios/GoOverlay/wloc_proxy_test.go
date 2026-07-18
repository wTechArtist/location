package libbox

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ecdsa"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

type testWlocPatcher struct{}

func (testWlocPatcher) PatchResponse(body []byte) ([]byte, error) { return body, nil }
func (testWlocPatcher) WriteLog(string)                           {}

type suffixWlocPatcher struct {
	calls int
}

func (p *suffixWlocPatcher) PatchResponse(body []byte) ([]byte, error) {
	p.calls++
	return append(body, []byte("-patched")...), nil
}

func (*suffixWlocPatcher) WriteLog(string) {}

func TestGenerateWlocCAAndLeaf(t *testing.T) {
	material, err := GenerateWlocCA()
	if err != nil {
		t.Fatal(err)
	}
	ca, err := x509.ParseCertificate(material.CertificateDER())
	if err != nil {
		t.Fatal(err)
	}
	if !ca.IsCA {
		t.Fatal("generated certificate is not a CA")
	}
	key, err := x509.ParsePKCS8PrivateKey(material.PrivateKeyDER())
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := key.(*ecdsa.PrivateKey); !ok {
		t.Fatalf("unexpected private key type %T", key)
	}

	proxy, err := NewWlocProxy(material.CertificateDER(), material.PrivateKeyDER(), testWlocPatcher{})
	if err != nil {
		t.Fatal(err)
	}
	leafPair, err := proxy.certificateForHost("gs-loc.apple.com")
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(leafPair.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	if _, err = leaf.Verify(x509.VerifyOptions{DNSName: "gs-loc.apple.com", Roots: roots}); err != nil {
		t.Fatalf("leaf certificate does not verify: %v", err)
	}
}

func TestReadResponseBodyDecodesGzip(t *testing.T) {
	original := []byte{0, 1, 2, 3, 0xff}
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	if _, err := writer.Write(original); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	response := &http.Response{
		Header: http.Header{"Content-Encoding": []string{"gzip"}},
		Body:   io.NopCloser(bytes.NewReader(compressed.Bytes())),
	}
	decoded, err := readResponseBody(response)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(decoded, original) {
		t.Fatalf("decoded body mismatch: %v", decoded)
	}
}

func TestReadResponseBodyRejectsUnsupportedEncoding(t *testing.T) {
	response := &http.Response{
		Header: http.Header{"Content-Encoding": []string{"br"}},
		Body:   io.NopCloser(strings.NewReader("compressed")),
	}

	_, err := readResponseBody(response)
	if err == nil || !strings.Contains(err.Error(), "unsupported WLOC content encoding") {
		t.Fatalf("expected unsupported encoding error, got %v", err)
	}
}

func TestNewWlocProxyRejectsMismatchedPrivateKey(t *testing.T) {
	ca, err := GenerateWlocCA()
	if err != nil {
		t.Fatal(err)
	}
	otherCA, err := GenerateWlocCA()
	if err != nil {
		t.Fatal(err)
	}

	_, err = NewWlocProxy(ca.CertificateDER(), otherCA.PrivateKeyDER(), testWlocPatcher{})
	if err == nil || !strings.Contains(err.Error(), "do not match") {
		t.Fatalf("expected certificate/key mismatch error, got %v", err)
	}
}

func TestLocalProxyLifecycle(t *testing.T) {
	material, err := GenerateWlocCA()
	if err != nil {
		t.Fatal(err)
	}
	proxy, err := NewWlocProxy(material.CertificateDER(), material.PrivateKeyDER(), testWlocPatcher{})
	if err != nil {
		t.Fatal(err)
	}
	if err = proxy.Start(); err != nil {
		t.Fatal(err)
	}
	if proxy.Port() <= 0 {
		t.Fatal("proxy did not publish a port")
	}
	if err = proxy.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestLocalProxyInterceptsTLSAndPatchesResponse(t *testing.T) {
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Host != "gs-loc.apple.com" {
			t.Errorf("unexpected upstream host %q", request.Host)
		}
		_, _ = writer.Write([]byte("protobuf"))
	}))
	defer upstream.Close()
	upstreamURL, err := url.Parse(upstream.URL)
	if err != nil {
		t.Fatal(err)
	}

	material, err := GenerateWlocCA()
	if err != nil {
		t.Fatal(err)
	}
	patcher := &suffixWlocPatcher{}
	proxy, err := NewWlocProxy(material.CertificateDER(), material.PrivateKeyDER(), patcher)
	if err != nil {
		t.Fatal(err)
	}
	proxy.transport = &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "tcp", upstreamURL.Host)
		},
		TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: true}, // test server only
	}
	if err = proxy.Start(); err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()

	rootCertificate, err := x509.ParseCertificate(material.CertificateDER())
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(rootCertificate)
	proxyURL, err := url.Parse("http://127.0.0.1:" + fmt.Sprint(proxy.Port()))
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Transport: &http.Transport{
		Proxy:             http.ProxyURL(proxyURL),
		ForceAttemptHTTP2: true,
		TLSClientConfig:   &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots},
	}}
	response, err := client.Get("https://gs-loc.apple.com/location")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "protobuf-patched" {
		t.Fatalf("unexpected patched body %q", body)
	}
	if patcher.calls != 1 {
		t.Fatalf("expected one patch callback, got %d", patcher.calls)
	}
}

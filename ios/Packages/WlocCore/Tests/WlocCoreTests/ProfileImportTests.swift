import XCTest
@testable import WlocCore

final class ProfileImportTests: XCTestCase {
    func testNormalizesSingBoxJSONWithTunInbound() throws {
        let source = Data(#"{"outbounds":[{"type":"direct","tag":"direct"}]}"#.utf8)

        let draft = try ProxyProfileImporter.importConfiguration(source, sourceName: "home.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: draft.configuration) as? [String: Any])
        let inbounds = try XCTUnwrap(root["inbounds"] as? [[String: Any]])

        XCTAssertEqual(draft.format, .singBoxJSON)
        XCTAssertEqual(draft.suggestedName, "home")
        XCTAssertTrue(draft.isUsable)
        XCTAssertTrue(inbounds.contains { $0["type"] as? String == "tun" })
    }

    func testConvertsShadowrocketNodesGroupsAndRules() throws {
        let source = """
        [General]
        ipv6 = true

        [Proxy]
        HK-SS = ss, hk.example.com, 8388, encrypt-method=aes-128-gcm, password=secret, udp-relay=true
        US-Trojan = trojan, us.example.com, 443, password=secret2, sni=edge.example.com

        [Proxy Group]
        Auto = url-test, HK-SS, US-Trojan, url=https://www.gstatic.com/generate_204, interval=600, tolerance=80
        Main = select, Auto, HK-SS, DIRECT

        [Rule]
        DOMAIN-SUFFIX, apple.com, DIRECT
        DOMAIN, example.org, Main
        IP-CIDR, 10.0.0.0/8, DIRECT, no-resolve
        FINAL, Main

        [MITM]
        hostname = gs-loc.apple.com, gs-loc-cn.apple.com
        """

        let draft = try ProxyProfileImporter.importConfiguration(Data(source.utf8), sourceName: "shadowrocket.conf")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: draft.configuration) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let route = try XCTUnwrap(root["route"] as? [String: Any])

        XCTAssertEqual(draft.format, .shadowrocket)
        XCTAssertTrue(draft.isUsable, draft.issues.map(\.message).joined(separator: " | "))
        XCTAssertEqual(route["final"] as? String, "Main")
        XCTAssertTrue(outbounds.contains { $0["type"] as? String == "shadowsocks" && $0["tag"] as? String == "HK-SS" })
        XCTAssertTrue(outbounds.contains { $0["type"] as? String == "trojan" && $0["tag"] as? String == "US-Trojan" })
        XCTAssertTrue(outbounds.contains { $0["type"] as? String == "urltest" && $0["tag"] as? String == "Auto" })
        XCTAssertTrue(outbounds.contains { $0["type"] as? String == "selector" && $0["tag"] as? String == "Main" })
        XCTAssertTrue(draft.issues.contains { $0.location == "[mitm]" && $0.severity == .warning })
        XCTAssertTrue(draft.issues.contains {
            $0.severity == .information && $0.message.contains("udp-relay=true")
        })
    }

    func testDefaultsUnmatchedTrafficToDirectAndReportsWarning() throws {
        let source = """
        [Proxy]
        HK-SS = ss, hk.example.com, 8388, encrypt-method=aes-128-gcm, password=secret
        """

        let draft = try ProxyProfileImporter.importConfiguration(Data(source.utf8), sourceName: "no-final.conf")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: draft.configuration) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])

        XCTAssertTrue(draft.isUsable, draft.issues.map(\.message).joined(separator: " | "))
        XCTAssertEqual(route["final"] as? String, "direct")
        XCTAssertTrue(draft.issues.contains {
            $0.severity == .warning && $0.message.contains("未匹配流量将默认直连")
        })
    }

    func testUnsupportedNodeMakesDraftUnusableWithoutDroppingReport() throws {
        let source = """
        [Proxy]
        Unsupported = hysteria2, host.example.com, 443, password=secret

        [Rule]
        FINAL, DIRECT
        """

        let draft = try ProxyProfileImporter.importConfiguration(Data(source.utf8), sourceName: "bad.conf")

        XCTAssertFalse(draft.isUsable)
        XCTAssertTrue(draft.issues.contains { $0.severity == .error && $0.message.contains("hysteria2") })
        XCTAssertTrue(draft.issues.contains { $0.severity == .error && $0.message.contains("没有可导入") })
    }

    func testRejectsUnknownInput() {
        XCTAssertThrowsError(
            try ProxyProfileImporter.importConfiguration(Data("not a supported profile".utf8), sourceName: "note.txt")
        )
    }
}

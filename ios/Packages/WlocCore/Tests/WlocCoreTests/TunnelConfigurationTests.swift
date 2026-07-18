import XCTest
@testable import WlocCore

final class TunnelConfigurationTests: XCTestCase {
    func testInjectsOnlyAllowlistedDomainsAndPreservesRouting() throws {
        let source = Data(#"{"inbounds":[{"type":"tun","tag":"tun-in"}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}"#.utf8)
        let data = try WlocTunnelConfiguration.injectingLocalMITM(into: source, port: 18_765)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inbounds = try XCTUnwrap(root["inbounds"] as? [[String: Any]])
        let platform = try XCTUnwrap(inbounds[0]["platform"] as? [String: Any])
        let proxy = try XCTUnwrap(platform["http_proxy"] as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])

        XCTAssertEqual(proxy["server"] as? String, "127.0.0.1")
        XCTAssertEqual(proxy["server_port"] as? Int, 18_765)
        XCTAssertEqual(proxy["match_domain"] as? [String], WlocTunnelConfiguration.interceptedDomains)
        XCTAssertEqual(route["final"] as? String, "direct")
    }

    func testRejectsMissingTunInbound() {
        XCTAssertThrowsError(
            try WlocTunnelConfiguration.injectingLocalMITM(into: Data(#"{"inbounds":[]}"#.utf8), port: 9_000)
        )
    }
}

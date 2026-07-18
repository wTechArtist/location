import XCTest
@testable import WlocCore

final class CertificateProfileTests: XCTestCase {
    func testBuildsInstallableRootCertificatePayload() throws {
        let certificate = Data([0x30, 0x03, 0x01, 0x02, 0x03])
        let data = try WlocCertificateProfile.make(certificateDER: certificate, identifierPrefix: "app.wloc.tests")
        let root = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let payloads = try XCTUnwrap(root["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(root["PayloadType"] as? String, "Configuration")
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0]["PayloadType"] as? String, "com.apple.security.root")
        XCTAssertEqual(payloads[0]["PayloadContent"] as? Data, certificate)
    }
}

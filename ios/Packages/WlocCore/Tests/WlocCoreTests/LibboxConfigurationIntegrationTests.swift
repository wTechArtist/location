import XCTest
@testable import WlocCore

#if canImport(Libbox)
import Libbox

final class LibboxConfigurationIntegrationTests: XCTestCase {
    func testNormalizedSingBoxConfigurationIsAcceptedByPinnedLibbox() throws {
        let source = Data(#"{"outbounds":[{"type":"direct","tag":"direct"}]}"#.utf8)
        let draft = try ProxyProfileImporter.importConfiguration(source, sourceName: "direct.json")
        try assertLibboxAccepts(draft.configuration)
    }

    func testConvertedShadowrocketConfigurationIsAcceptedByPinnedLibbox() throws {
        let source = """
        [Proxy]
        Node = ss, 127.0.0.1, 8388, encrypt-method=aes-128-gcm, password=fixture-only

        [Rule]
        FINAL, Node
        """
        let draft = try ProxyProfileImporter.importConfiguration(Data(source.utf8), sourceName: "fixture.conf")
        XCTAssertTrue(draft.isUsable, draft.issues.map(\.message).joined(separator: " | "))
        try assertLibboxAccepts(draft.configuration)
    }

    private func assertLibboxAccepts(_ configuration: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try XCTUnwrap(String(data: configuration, encoding: .utf8), file: file, line: line)
        var validationError: NSError?
        let accepted = LibboxCheckConfig(text, &validationError)
        XCTAssertNil(validationError, validationError?.localizedDescription ?? "", file: file, line: line)
        XCTAssertTrue(accepted, "Libbox rejected the generated configuration without an NSError", file: file, line: line)
    }
}
#endif

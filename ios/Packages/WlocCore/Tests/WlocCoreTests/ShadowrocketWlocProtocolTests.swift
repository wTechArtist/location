import Foundation
import Testing
@testable import WlocCore

@Suite("Shadowrocket WLOC Settings protocol")
struct ShadowrocketWlocProtocolTests {
    @Test("save URL preserves signed and zero coordinates")
    func saveURL() throws {
        let coordinate = try WlocCoordinate(latitude: 0, longitude: -73.985_428)
        let target = try WlocTarget(mode: .override, coordinate: coordinate, accuracy: 37)
        let components = try #require(URLComponents(url: try ShadowrocketWlocRequest.save(target).url(), resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.scheme == "https")
        #expect(components.host == "gs-loc.apple.com")
        #expect(values["lon"] == "-73.985428")
        #expect(values["lat"] == "0.0")
        #expect(values["acc"] == "37")
    }

    @Test("query and clear URLs use explicit actions")
    func actionURLs() throws {
        #expect(try ShadowrocketWlocRequest.query.url().query == "action=query")
        #expect(try ShadowrocketWlocRequest.clear.url().query == "action=clear")
    }

    @Test("query response maps saved coordinate")
    func savedResponse() throws {
        let data = Data(#"{"success":true,"longitude":114.1694,"latitude":22.3193,"accuracy":25}"#.utf8)
        let target = try ShadowrocketWlocResponse.decode(data).targetForQuery()

        #expect(target.mode == .override)
        #expect(target.coordinate == (try WlocCoordinate(latitude: 22.3193, longitude: 114.1694)))
    }

    @Test("no saved coordinate maps to passthrough")
    func emptyResponse() throws {
        let data = Data(#"{"success":false,"error":"无已保存的坐标"}"#.utf8)
        #expect(try ShadowrocketWlocResponse.decode(data).targetForQuery().mode == .passthrough)
    }

    @Test("non-module response is rejected")
    func invalidResponse() {
        #expect(throws: WlocCoreError.self) {
            try ShadowrocketWlocResponse.decode(Data("not json".utf8))
        }
    }
}

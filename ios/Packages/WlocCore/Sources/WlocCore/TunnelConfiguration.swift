import Foundation

public enum WlocTunnelConfiguration {
    public static let interceptedDomains = ["gs-loc.apple.com", "gs-loc-cn.apple.com"]

    /// Uses sing-box's Apple `tun.platform.http_proxy` hook. NetworkExtension then
    /// applies an `NEProxySettings.matchDomains` list, so only these two HTTPS hosts
    /// issue CONNECT requests to the device-local MITM listener.
    public static func injectingLocalMITM(into configuration: Data, port: Int) throws -> Data {
        guard (1 ... 65_535).contains(port),
              var root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              var inbounds = root["inbounds"] as? [[String: Any]],
              let tunIndex = inbounds.firstIndex(where: { $0["type"] as? String == "tun" })
        else {
            throw WlocCoreError.malformedInput("配置缺少有效 tun 入站或本地 MITM 端口")
        }
        var tun = inbounds[tunIndex]
        var platform = tun["platform"] as? [String: Any] ?? [:]
        platform["http_proxy"] = [
            "enabled": true,
            "server": "127.0.0.1",
            "server_port": port,
            "match_domain": interceptedDomains,
        ]
        tun["platform"] = platform
        inbounds[tunIndex] = tun
        root["inbounds"] = inbounds
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

import NetworkExtension

#if canImport(Libbox)
import Libbox

final class PacketTunnelProvider: WlocLibboxPacketTunnelProvider {}
#else
/// This branch keeps the Xcode project buildable before the pinned Libbox XCFramework
/// is produced on macOS. It intentionally fails closed instead of reporting a fake VPN.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options _: [String: NSObject]?) async throws {
        throw NSError(
            domain: "app.wloc.packet-tunnel",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "缺少 Libbox.xcframework；请先在 macOS 运行 ios/scripts/bootstrap-macos.sh。",
            ]
        )
    }
}
#endif

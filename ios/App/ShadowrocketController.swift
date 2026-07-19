import Foundation
import UIKit

@MainActor
struct ShadowrocketController {
    enum Command: String {
        case open
        case connect
        case disconnect

        var url: URL {
            URL(string: "shadowrocket://\(rawValue)")!
        }

        var label: String {
            switch self {
            case .open: "打开 Shadowrocket"
            case .connect: "连接"
            case .disconnect: "断开"
            }
        }
    }

    var isInstalled: Bool {
        UIApplication.shared.canOpenURL(Command.open.url)
    }

    func send(_ command: Command) async throws {
        guard isInstalled else { throw ShadowrocketControllerError.notInstalled }
        let accepted = await withCheckedContinuation { continuation in
            UIApplication.shared.open(command.url, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }
        guard accepted else { throw ShadowrocketControllerError.commandRejected(command.label) }
    }
}

enum ShadowrocketControllerError: Error, LocalizedError {
    case notInstalled
    case commandRejected(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "未检测到 Shadowrocket。请先从 App Store 安装，然后回到 WLOC。"
        case let .commandRejected(command):
            "iOS 未接受 Shadowrocket 的“\(command)”指令。请手动打开 Shadowrocket 完成操作。"
        }
    }
}

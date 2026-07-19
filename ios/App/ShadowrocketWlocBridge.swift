import Foundation
import WlocCore

struct ShadowrocketWlocBridge {
    var session: URLSession = .shared

    func currentTarget() async throws -> WlocTarget {
        try await perform(.query).targetForQuery()
    }

    func apply(_ target: WlocTarget) async throws {
        let request: ShadowrocketWlocRequest = target.mode == .override ? .save(target) : .clear
        let response = try await perform(request)
        guard response.success else {
            throw ShadowrocketWlocBridgeError.moduleRejected(response.error ?? "未知错误")
        }

        let confirmed = try await currentTarget()
        guard confirmed.sameRemoteValue(as: target) else {
            throw ShadowrocketWlocBridgeError.targetMismatch(expected: target, actual: confirmed)
        }
    }

    private func perform(_ operation: ShadowrocketWlocRequest) async throws -> ShadowrocketWlocResponse {
        var request = URLRequest(url: try operation.url())
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ShadowrocketWlocBridgeError.invalidHTTPResponse
            }
            return try ShadowrocketWlocResponse.decode(data)
        } catch let error as ShadowrocketWlocBridgeError {
            throw error
        } catch let error as WlocCoreError {
            throw ShadowrocketWlocBridgeError.moduleUnavailable(error.localizedDescription)
        } catch {
            throw ShadowrocketWlocBridgeError.moduleUnavailable(error.localizedDescription)
        }
    }
}

private extension WlocTarget {
    func sameRemoteValue(as other: WlocTarget) -> Bool {
        guard mode == other.mode else { return false }
        if mode == .passthrough { return true }
        guard let lhs = coordinate, let rhs = other.coordinate else { return false }
        return abs(lhs.latitude - rhs.latitude) < 0.000_000_1
            && abs(lhs.longitude - rhs.longitude) < 0.000_000_1
            && accuracy == other.accuracy
    }
}

enum ShadowrocketWlocBridgeError: Error, LocalizedError {
    case invalidHTTPResponse
    case moduleUnavailable(String)
    case moduleRejected(String)
    case targetMismatch(expected: WlocTarget, actual: WlocTarget)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            "WLOC Settings 没有返回 HTTP 200。请确认 Shadowrocket 已连接且 WLOC 模块已启用。"
        case let .moduleUnavailable(reason):
            "无法通过 Shadowrocket 访问 WLOC 模块：\(reason)"
        case let .moduleRejected(reason):
            "Shadowrocket 的 WLOC 模块拒绝了请求：\(reason)"
        case .targetMismatch:
            "写入后的坐标查询结果不一致，因此不会把本次操作报告为成功。"
        }
    }
}

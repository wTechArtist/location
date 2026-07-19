import Foundation

public enum ShadowrocketActionURL {
    public static func installModule(_ moduleURL: URL) throws -> URL {
        guard moduleURL.scheme?.lowercased() == "https", moduleURL.host != nil else {
            throw WlocCoreError.malformedInput("WLOC 模块下载地址必须是 HTTPS")
        }

        var components = URLComponents()
        components.scheme = "shadowrocket"
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "module", value: moduleURL.absoluteString)]
        guard let url = components.url else {
            throw WlocCoreError.malformedInput("无法生成 Shadowrocket 模块安装链接")
        }
        return url
    }
}

public enum ShadowrocketWlocRequest: Equatable, Sendable {
    case save(WlocTarget)
    case query
    case clear

    public func url(baseURL: URL = Self.defaultBaseURL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw WlocCoreError.malformedInput("WLOC Settings 地址无效")
        }

        switch self {
        case let .save(target):
            guard target.mode == .override, let coordinate = target.coordinate else {
                throw WlocCoreError.missingCoordinate
            }
            components.queryItems = [
                URLQueryItem(name: "lon", value: String(coordinate.longitude)),
                URLQueryItem(name: "lat", value: String(coordinate.latitude)),
                URLQueryItem(name: "acc", value: String(target.accuracy)),
            ]
        case .query:
            components.queryItems = [URLQueryItem(name: "action", value: "query")]
        case .clear:
            components.queryItems = [URLQueryItem(name: "action", value: "clear")]
        }

        guard let url = components.url else {
            throw WlocCoreError.malformedInput("无法生成 WLOC Settings 请求")
        }
        return url
    }

    public static let defaultBaseURL = URL(string: "https://gs-loc.apple.com/wloc-settings/save")!
}

public struct ShadowrocketWlocResponse: Codable, Equatable, Sendable {
    public var success: Bool
    public var longitude: Double?
    public var latitude: Double?
    public var accuracy: Int?
    public var updatedAt: String?
    public var error: String?

    public init(
        success: Bool,
        longitude: Double? = nil,
        latitude: Double? = nil,
        accuracy: Int? = nil,
        updatedAt: String? = nil,
        error: String? = nil
    ) {
        self.success = success
        self.longitude = longitude
        self.latitude = latitude
        self.accuracy = accuracy
        self.updatedAt = updatedAt
        self.error = error
    }

    public static func decode(_ data: Data) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw WlocCoreError.malformedInput("Shadowrocket 未返回 WLOC Settings JSON；请确认模块已启用且 MITM 证书已完全信任")
        }
    }

    public func targetForQuery() throws -> WlocTarget {
        if success {
            guard let longitude, let latitude else {
                throw WlocCoreError.malformedInput("WLOC Settings 查询成功但缺少坐标")
            }
            let coordinate = try WlocCoordinate(latitude: latitude, longitude: longitude)
            return try WlocTarget(mode: .override, coordinate: coordinate, accuracy: accuracy ?? 25)
        }

        if error == "无已保存的坐标" {
            return .passthrough
        }
        throw WlocCoreError.malformedInput(error ?? "Shadowrocket 模块拒绝了请求")
    }
}

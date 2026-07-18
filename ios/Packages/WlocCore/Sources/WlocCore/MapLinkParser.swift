import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ParsedMapLocation: Hashable, Sendable {
    public enum Source: String, Sendable {
        case apple
        case amap
        case text
    }

    public var coordinate: WlocCoordinate
    public var name: String
    public var source: Source

    public init(coordinate: WlocCoordinate, name: String, source: Source) {
        self.coordinate = coordinate
        self.name = name
        self.source = source
    }
}

public enum MapLinkParser {
    public static func extract(from raw: String) throws -> ParsedMapLocation? {
        let text = raw.removingPercentEncoding ?? raw
        if let values = firstMatch(#"(?:coordinate|ll|sll)=(-?\d{1,3}\.\d+),(-?\d{1,3}\.\d+)"#, in: text), values.count == 2 {
            let name = firstMatch(#"[?&]name=([^&]+)"#, in: text)?.first?.removingPercentEncoding ?? ""
            return try parsed(values, name: name, source: .apple)
        }
        if let values = firstMatch(#"[?&]p=[^,&]*,(-?\d{1,3}\.\d+),(-?\d{1,3}\.\d+)(?:,([^,&]+))?"#, in: text), values.count >= 2 {
            return try parsed(Array(values.prefix(2)), name: values.count > 2 ? values[2] : "", source: .amap)
        }
        if let values = firstMatch(#"[?&]q=(-?\d{1,3}\.\d+),(-?\d{1,3}\.\d+)(?:,([^,&]+))?"#, in: text), values.count >= 2 {
            return try parsed(Array(values.prefix(2)), name: values.count > 2 ? values[2] : "", source: .amap)
        }
        if let values = firstMatch(#"(-?\d{1,3}\.\d{4,})\s*,\s*(-?\d{1,3}\.\d{4,})"#, in: text), values.count == 2 {
            return try parsed(values, name: "", source: .text)
        }
        return nil
    }

    public static func resolve(_ raw: String, maximumRedirects: Int = 5) async throws -> ParsedMapLocation {
        if let direct = try extract(from: raw) {
            return try normalize(direct)
        }
        guard let url = firstURL(in: raw) else {
            throw WlocCoreError.malformedInput("未找到地图链接或坐标")
        }
        var current = url
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        for _ in 0 ... maximumRedirects {
            var request = URLRequest(url: current)
            request.timeoutInterval = 15
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            if let responseURL = response.url, let hit = try extract(from: responseURL.absoluteString) {
                return try normalize(hit)
            }
            if let http = response as? HTTPURLResponse,
               let location = http.value(forHTTPHeaderField: "Location"),
               let next = URL(string: location, relativeTo: current)?.absoluteURL
            {
                if let hit = try extract(from: next.absoluteString) {
                    return try normalize(hit)
                }
                current = next
                continue
            }
            if let body = String(data: data.prefix(1_000_000), encoding: .utf8), let hit = try extract(from: body) {
                return try normalize(hit)
            }
            break
        }
        throw WlocCoreError.malformedInput("未能从地图链接解析坐标")
    }

    private static func parsed(_ values: [String], name: String, source: ParsedMapLocation.Source) throws -> ParsedMapLocation {
        guard values.count >= 2, let latitude = Double(values[0]), let longitude = Double(values[1]) else {
            throw WlocCoreError.malformedInput("经纬度不是有效数字")
        }
        return ParsedMapLocation(
            coordinate: try WlocCoordinate(latitude: latitude, longitude: longitude),
            name: name.removingPercentEncoding ?? name,
            source: source
        )
    }

    private static func normalize(_ location: ParsedMapLocation) throws -> ParsedMapLocation {
        guard location.source == .apple || location.source == .amap else { return location }
        var result = location
        result.coordinate = try CoordinateConversion.gcj02ToWGS84(location.coordinate)
        return result
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1 ..< match.numberOfRanges).compactMap { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static func firstURL(in text: String) -> URL? {
        guard let expression = try? NSRegularExpression(pattern: #"https?://[^\s'\"<>]+"#, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return URL(string: String(text[range]))
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

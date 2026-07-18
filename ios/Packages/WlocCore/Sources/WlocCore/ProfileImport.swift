import Foundation

public enum ProxyProfileFormat: String, Codable, Sendable {
    case singBoxJSON
    case shadowrocket
}

public struct ProfileImportIssue: Codable, Equatable, Identifiable, Sendable {
    public enum Severity: String, Codable, Sendable {
        case information
        case warning
        case error
    }

    public var id: UUID
    public var severity: Severity
    public var location: String
    public var message: String

    public init(id: UUID = UUID(), severity: Severity, location: String, message: String) {
        self.id = id
        self.severity = severity
        self.location = location
        self.message = message
    }
}

public struct ImportedProfileDraft: Sendable {
    public var suggestedName: String
    public var format: ProxyProfileFormat
    public var configuration: Data
    public var issues: [ProfileImportIssue]

    public var isUsable: Bool {
        !issues.contains { $0.severity == .error }
    }

    public init(suggestedName: String, format: ProxyProfileFormat, configuration: Data, issues: [ProfileImportIssue]) {
        self.suggestedName = suggestedName
        self.format = format
        self.configuration = configuration
        self.issues = issues
    }
}

public enum ProxyProfileImporter {
    public static func importConfiguration(_ data: Data, sourceName: String) throws -> ImportedProfileDraft {
        guard data.count <= 10 * 1_024 * 1_024 else {
            throw WlocCoreError.malformedInput("配置文件超过 10 MB")
        }
        if let object = try? JSONSerialization.jsonObject(with: data), var root = object as? [String: Any] {
            var issues: [ProfileImportIssue] = []
            try normalizeSingBoxConfiguration(&root, issues: &issues)
            let configuration = try serialized(root)
            return ImportedProfileDraft(
                suggestedName: profileName(from: sourceName),
                format: .singBoxJSON,
                configuration: configuration,
                issues: issues
            )
        }

        guard let text = decodeText(data), text.range(of: #"(?im)^\s*\[(general|proxy|rule)\]\s*$"#, options: .regularExpression) != nil else {
            throw WlocCoreError.unsupportedFormat("仅支持 sing-box JSON 或 Shadowrocket .conf")
        }
        return try ShadowrocketImporter.importConfiguration(text, sourceName: sourceName)
    }
}

private extension ProxyProfileImporter {
    static func normalizeSingBoxConfiguration(_ root: inout [String: Any], issues: inout [ProfileImportIssue]) throws {
        guard root["outbounds"] is [[String: Any]] else {
            throw WlocCoreError.malformedInput("sing-box 配置缺少 outbounds 数组")
        }
        var inbounds = root["inbounds"] as? [[String: Any]] ?? []
        if !inbounds.contains(where: { ($0["type"] as? String) == "tun" }) {
            inbounds.insert(defaultTunInbound(), at: 0)
            issues.append(.init(
                severity: .information,
                location: "inbounds",
                message: "已添加 iOS Packet Tunnel 所需的 tun 入站。"
            ))
        }
        root["inbounds"] = inbounds

        if root["route"] == nil {
            root["route"] = ["rules": []]
            issues.append(.init(severity: .information, location: "route", message: "已添加空路由配置。"))
        }
        if root["dns"] == nil {
            root["dns"] = defaultDNS()
            issues.append(.init(severity: .information, location: "dns", message: "已添加使用系统解析器的本地 DNS 配置。"))
        }
        guard JSONSerialization.isValidJSONObject(root) else {
            throw WlocCoreError.malformedInput("sing-box JSON 含无法序列化的值")
        }
    }

    static func defaultTunInbound() -> [String: Any] {
        [
            "type": "tun",
            "tag": "tun-in",
            "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
            "auto_route": true,
            "strict_route": true,
            "stack": "system",
        ]
    }

    static func defaultDNS() -> [String: Any] {
        [
            "servers": [["type": "local", "tag": "local-dns"]],
            "final": "local-dns",
            "strategy": "prefer_ipv4",
        ]
    }

    static func serialized(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ??
            String(data: data, encoding: .utf16) ??
            String(data: data, encoding: .isoLatin1)
    }

    static func profileName(from sourceName: String) -> String {
        let name = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
        return name.isEmpty ? "导入的配置" : String(name.prefix(60))
    }
}

private enum ShadowrocketImporter {
    struct SourceLine {
        var number: Int
        var text: String
    }

    struct ParsedFile {
        var sections: [String: [SourceLine]]
    }

    static func importConfiguration(_ text: String, sourceName: String) throws -> ImportedProfileDraft {
        let parsed = parseSections(text)
        var issues: [ProfileImportIssue] = []
        var outbounds: [[String: Any]] = []
        var knownTags: Set<String> = ["direct", "block"]

        for line in parsed.sections["proxy"] ?? [] {
            do {
                let outbound = try parseProxy(line, issues: &issues)
                guard let tag = outbound["tag"] as? String else { continue }
                if knownTags.contains(tag) {
                    issues.append(issue(.error, line, "节点名称重复：\(tag)"))
                } else {
                    knownTags.insert(tag)
                    outbounds.append(outbound)
                }
            } catch {
                issues.append(issue(.error, line, error.localizedDescription))
            }
        }

        if outbounds.isEmpty {
            issues.append(.init(severity: .error, location: "[Proxy]", message: "没有可导入的代理节点。"))
        }

        var groupLines: [(line: SourceLine, name: String, values: [String])] = []
        for line in parsed.sections["proxy group"] ?? [] {
            guard let (name, rawValue) = assignment(line.text) else {
                issues.append(issue(.error, line, "策略组缺少“名称 = 类型, 节点…”结构。"))
                continue
            }
            let values = splitCSV(rawValue)
            guard !name.isEmpty, values.count >= 2 else {
                issues.append(issue(.error, line, "策略组至少需要一种类型和一个成员。"))
                continue
            }
            if knownTags.contains(name) {
                issues.append(issue(.error, line, "策略组名称重复：\(name)"))
                continue
            }
            knownTags.insert(name)
            groupLines.append((line, name, values))
        }

        for group in groupLines {
            if let outbound = parseGroup(group.line, name: group.name, values: group.values, knownTags: knownTags, issues: &issues) {
                outbounds.append(outbound)
            }
        }
        outbounds.append(["type": "direct", "tag": "direct"])
        outbounds.append(["type": "block", "tag": "block"])

        let rulesResult = parseRules(parsed.sections["rule"] ?? [], knownTags: knownTags, issues: &issues)
        inspectGeneral(parsed.sections["general"] ?? [], issues: &issues)
        inspectUnsupportedSections(parsed, issues: &issues)

        var route: [String: Any] = ["rules": rulesResult.rules]
        let fallback: String
        if let configuredFinal = rulesResult.finalOutbound {
            fallback = configuredFinal
        } else {
            fallback = "direct"
            issues.append(.init(
                severity: .warning,
                location: "[Rule]",
                message: "未发现 FINAL/MATCH 规则；未匹配流量将默认直连。"
            ))
        }
        route["final"] = fallback

        let configuration: [String: Any] = [
            "log": ["level": "info", "timestamp": true],
            "dns": ProxyProfileImporter.defaultDNS(),
            "inbounds": [ProxyProfileImporter.defaultTunInbound()],
            "outbounds": outbounds,
            "route": route,
        ]

        return ImportedProfileDraft(
            suggestedName: ProxyProfileImporter.profileName(from: sourceName),
            format: .shadowrocket,
            configuration: try ProxyProfileImporter.serialized(configuration),
            issues: issues
        )
    }
}

private extension ShadowrocketImporter {
    static func parseSections(_ text: String) -> ParsedFile {
        var result: [String: [SourceLine]] = [:]
        var section = ""
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (index, substring) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("#"), !text.hasPrefix(";") else { continue }
            if text.hasPrefix("["), text.hasSuffix("]") {
                section = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                continue
            }
            guard !section.isEmpty else { continue }
            result[section, default: []].append(SourceLine(number: index + 1, text: text))
        }
        return ParsedFile(sections: result)
    }

    static func parseProxy(_ line: SourceLine, issues: inout [ProfileImportIssue]) throws -> [String: Any] {
        guard let (rawName, rawValue) = assignment(line.text) else {
            throw WlocCoreError.malformedInput("节点缺少“名称 = 类型, 服务器, 端口”结构")
        }
        let name = normalizedTag(rawName)
        let tokens = splitCSV(rawValue)
        guard tokens.count >= 3 else {
            throw WlocCoreError.malformedInput("节点参数不足")
        }
        let type = tokens[0].lowercased()
        let server = tokens[1]
        guard !name.isEmpty, !server.isEmpty, let port = Int(tokens[2]), (1 ... 65_535).contains(port) else {
            throw WlocCoreError.malformedInput("节点名称、服务器或端口无效")
        }
        let parsedOptions = options(tokens.dropFirst(3))
        let values = parsedOptions.values
        let positional = parsedOptions.positional
        var consumed: Set<String> = []
        var outbound: [String: Any] = ["tag": name, "server": server, "server_port": port]

        for behavioralOption in ["udp-relay", "tfo", "fast-open"] where values[behavioralOption] != nil {
            consumed.insert(behavioralOption)
            issues.append(issue(
                .information,
                line,
                "节点选项 \(behavioralOption)=\(values[behavioralOption]!) 不直接复制；请在导入后真机核验对应 UDP/TCP 行为。"
            ))
        }

        switch type {
        case "ss", "shadowsocks":
            outbound["type"] = "shadowsocks"
            outbound["method"] = requiredOption(["encrypt-method", "method"], values: values, consumed: &consumed) ?? ""
            outbound["password"] = requiredOption(["password"], values: values, consumed: &consumed) ?? positional.first ?? ""
            if (outbound["method"] as? String)?.isEmpty != false || (outbound["password"] as? String)?.isEmpty != false {
                throw WlocCoreError.malformedInput("Shadowsocks 节点缺少 encrypt-method 或 password")
            }
            if values["obfs"] != nil || values["plugin"] != nil {
                issues.append(issue(.error, line, "此 Shadowsocks 插件/混淆尚不能安全转换。"))
                consumed.formUnion(["obfs", "plugin", "obfs-host", "obfs-uri"])
            }
        case "trojan":
            outbound["type"] = "trojan"
            outbound["password"] = requiredOption(["password"], values: values, consumed: &consumed) ?? positional.first ?? ""
            if (outbound["password"] as? String)?.isEmpty != false {
                throw WlocCoreError.malformedInput("Trojan 节点缺少 password")
            }
            outbound["tls"] = tlsOptions(values, defaultEnabled: true, consumed: &consumed)
            attachTransport(&outbound, values: values, consumed: &consumed)
        case "vmess":
            outbound["type"] = "vmess"
            outbound["uuid"] = requiredOption(["uuid"], values: values, consumed: &consumed) ?? positional.first ?? ""
            if (outbound["uuid"] as? String)?.isEmpty != false {
                throw WlocCoreError.malformedInput("VMess 节点缺少 uuid")
            }
            if let alterID = intOption("alterid", values: values, consumed: &consumed) ?? intOption("alter-id", values: values, consumed: &consumed) {
                outbound["alter_id"] = alterID
            }
            if let security = option("security", values: values, consumed: &consumed) {
                outbound["security"] = security
            }
            let tls = tlsOptions(values, defaultEnabled: false, consumed: &consumed)
            if (tls["enabled"] as? Bool) == true { outbound["tls"] = tls }
            attachTransport(&outbound, values: values, consumed: &consumed)
        case "vless":
            outbound["type"] = "vless"
            outbound["uuid"] = requiredOption(["uuid"], values: values, consumed: &consumed) ?? positional.first ?? ""
            if (outbound["uuid"] as? String)?.isEmpty != false {
                throw WlocCoreError.malformedInput("VLESS 节点缺少 uuid")
            }
            if let flow = option("flow", values: values, consumed: &consumed) { outbound["flow"] = flow }
            let tls = tlsOptions(values, defaultEnabled: false, consumed: &consumed)
            if (tls["enabled"] as? Bool) == true { outbound["tls"] = tls }
            attachTransport(&outbound, values: values, consumed: &consumed)
        case "http", "https":
            outbound["type"] = "http"
            if let username = option("username", values: values, consumed: &consumed) ?? positional.first {
                outbound["username"] = username
            }
            if let password = option("password", values: values, consumed: &consumed) ?? positional.dropFirst().first {
                outbound["password"] = password
            }
            let tls = tlsOptions(values, defaultEnabled: type == "https", consumed: &consumed)
            if (tls["enabled"] as? Bool) == true { outbound["tls"] = tls }
        case "socks", "socks5":
            outbound["type"] = "socks"
            outbound["version"] = "5"
            if let username = option("username", values: values, consumed: &consumed) ?? positional.first {
                outbound["username"] = username
            }
            if let password = option("password", values: values, consumed: &consumed) ?? positional.dropFirst().first {
                outbound["password"] = password
            }
        default:
            throw WlocCoreError.unsupportedFormat("Shadowrocket 节点类型 \(type)")
        }

        let benign = Set(["skip-cert-verify", "tls", "sni", "peer", "servername", "ws", "ws-path", "ws-headers", "host"])
        let unknown = Set(values.keys).subtracting(consumed).subtracting(benign)
        if !unknown.isEmpty {
            issues.append(issue(.warning, line, "未转换的节点选项：\(unknown.sorted().joined(separator: ", "))"))
        }
        return outbound
    }

    static func parseGroup(
        _ line: SourceLine,
        name: String,
        values: [String],
        knownTags: Set<String>,
        issues: inout [ProfileImportIssue]
    ) -> [String: Any]? {
        let rawType = values[0].lowercased()
        let parsed = options(values.dropFirst())
        let members = parsed.positional.map(normalizedReference)
        let missing = members.filter { !knownTags.contains($0) }
        if !missing.isEmpty {
            issues.append(issue(.error, line, "策略组引用了不存在的成员：\(missing.joined(separator: ", "))"))
        }
        guard !members.isEmpty else {
            issues.append(issue(.error, line, "策略组没有成员。"))
            return nil
        }

        switch rawType {
        case "select", "static":
            return ["type": "selector", "tag": name, "outbounds": members]
        case "url-test":
            let interval = durationSeconds(parsed.values["interval"]) ?? 300
            let tolerance = Int(parsed.values["tolerance"] ?? "") ?? 50
            return [
                "type": "urltest",
                "tag": name,
                "outbounds": members,
                "url": parsed.values["url"] ?? "https://www.gstatic.com/generate_204",
                "interval": "\(interval)s",
                "tolerance": tolerance,
            ]
        case "fallback", "load-balance":
            issues.append(issue(.warning, line, "\(rawType) 已降级为手动 selector；不会静默改变选中的节点。"))
            return ["type": "selector", "tag": name, "outbounds": members]
        default:
            issues.append(issue(.error, line, "不支持的策略组类型：\(rawType)"))
            return nil
        }
    }

    static func parseRules(
        _ lines: [SourceLine],
        knownTags: Set<String>,
        issues: inout [ProfileImportIssue]
    ) -> (rules: [[String: Any]], finalOutbound: String?) {
        var rules: [[String: Any]] = []
        var finalOutbound: String?
        for line in lines {
            let parts = splitCSV(line.text)
            guard parts.count >= 2 else {
                issues.append(issue(.error, line, "规则字段不足。"))
                continue
            }
            let kind = parts[0].uppercased()
            if kind == "FINAL" || kind == "MATCH" {
                let target = normalizedReference(parts[1])
                if knownTags.contains(target) { finalOutbound = target } else {
                    issues.append(issue(.error, line, "FINAL 引用了不存在的策略：\(target)"))
                }
                continue
            }
            guard parts.count >= 3 else {
                issues.append(issue(.error, line, "规则缺少目标策略。"))
                continue
            }
            let value = parts[1]
            let target = normalizedReference(parts[2])
            guard knownTags.contains(target) else {
                issues.append(issue(.error, line, "规则引用了不存在的策略：\(target)"))
                continue
            }
            let key: String
            switch kind {
            case "DOMAIN": key = "domain"
            case "DOMAIN-SUFFIX": key = "domain_suffix"
            case "DOMAIN-KEYWORD": key = "domain_keyword"
            case "IP-CIDR", "IP-CIDR6": key = "ip_cidr"
            case "USER-AGENT":
                issues.append(issue(.error, line, "当前 sing-box 路由不能等价转换 USER-AGENT 规则。"))
                continue
            case "PROCESS-NAME":
                issues.append(issue(.warning, line, "iOS Packet Tunnel 无法可靠匹配 PROCESS-NAME，已拒绝此规则。"))
                continue
            default:
                issues.append(issue(.error, line, "不支持的规则类型：\(kind)"))
                continue
            }
            var rule: [String: Any] = [key: [value], "outbound": target]
            if parts.dropFirst(3).contains(where: { $0.lowercased() == "no-resolve" }) {
                issues.append(issue(.information, line, "no-resolve 不需要写入 sing-box 路由，规则匹配保持不变。"))
            }
            rules.append(rule)
        }
        return (rules, finalOutbound)
    }

    static func inspectGeneral(_ lines: [SourceLine], issues: inout [ProfileImportIssue]) {
        for line in lines {
            guard let (name, _) = assignment(line.text) else {
                issues.append(issue(.warning, line, "无法解析的 [General] 设置。"))
                continue
            }
            issues.append(issue(
                .information,
                line,
                "[General] 的 \(name) 不直接复制；网络、DNS 与路由由 App 的 sing-box 模板统一管理。"
            ))
        }
    }

    static func inspectUnsupportedSections(_ parsed: ParsedFile, issues: inout [ProfileImportIssue]) {
        let supported = Set(["general", "proxy", "proxy group", "rule"])
        for section in parsed.sections.keys where !supported.contains(section) {
            if section == "mitm" || section == "script" || section == "rewrite" || section == "url rewrite" {
                issues.append(.init(
                    severity: .warning,
                    location: "[\(section)]",
                    message: "该段不会导入；WLOC 拦截由 App 内置链路负责，其他脚本/重写不受支持。"
                ))
            } else {
                issues.append(.init(severity: .warning, location: "[\(section)]", message: "该配置段未转换。"))
            }
        }
    }

    static func tlsOptions(_ values: [String: String], defaultEnabled: Bool, consumed: inout Set<String>) -> [String: Any] {
        var tls: [String: Any] = ["enabled": bool(values["tls"]) ?? defaultEnabled]
        if values["tls"] != nil { consumed.insert("tls") }
        if let serverName = requiredOption(["sni", "peer", "servername"], values: values, consumed: &consumed) {
            tls["server_name"] = serverName
        }
        if let insecure = bool(values["skip-cert-verify"]) {
            consumed.insert("skip-cert-verify")
            tls["insecure"] = insecure
        }
        return tls
    }

    static func attachTransport(_ outbound: inout [String: Any], values: [String: String], consumed: inout Set<String>) {
        let usesWebSocket = bool(values["ws"]) == true || values["obfs"]?.lowercased() == "websocket"
        guard usesWebSocket else { return }
        consumed.formUnion(["ws", "obfs"])
        var transport: [String: Any] = ["type": "ws"]
        if let path = option("ws-path", values: values, consumed: &consumed) { transport["path"] = path }
        if let host = option("host", values: values, consumed: &consumed) {
            transport["headers"] = ["Host": host]
        } else if let headers = option("ws-headers", values: values, consumed: &consumed), !headers.isEmpty {
            transport["headers"] = ["Host": headers]
        }
        outbound["transport"] = transport
    }

    static func assignment(_ text: String) -> (String, String)? {
        guard let index = text.firstIndex(of: "=") else { return nil }
        let name = text[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = text[text.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, value)
    }

    static func splitCSV<S: StringProtocol>(_ input: S) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        for character in input {
            if escaping {
                current.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "\"" || character == "'" {
                if quote == character { quote = nil } else if quote == nil { quote = character } else { current.append(character) }
            } else if character == ",", quote == nil {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaping { current.append("\\") }
        result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return result
    }

    static func options<S: Sequence>(_ values: S) -> (values: [String: String], positional: [String]) where S.Element == String {
        var options: [String: String] = [:]
        var positional: [String] = []
        for token in values {
            if let index = token.firstIndex(of: "=") {
                let key = token[..<index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = token[token.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
                options[key] = value
            } else if !token.isEmpty {
                positional.append(token)
            }
        }
        return (options, positional)
    }

    static func option(_ key: String, values: [String: String], consumed: inout Set<String>) -> String? {
        guard let value = values[key], !value.isEmpty else { return nil }
        consumed.insert(key)
        return value
    }

    static func requiredOption(_ keys: [String], values: [String: String], consumed: inout Set<String>) -> String? {
        for key in keys where values[key]?.isEmpty == false {
            consumed.insert(key)
            return values[key]
        }
        return nil
    }

    static func intOption(_ key: String, values: [String: String], consumed: inout Set<String>) -> Int? {
        guard let raw = values[key], let value = Int(raw) else { return nil }
        consumed.insert(key)
        return value
    }

    static func normalizedTag(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }

    static func normalizedReference(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "DIRECT": "direct"
        case "REJECT", "REJECT-TINYGIF", "REJECT-DROP": "block"
        default: normalizedTag(value)
        }
    }

    static func bool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "true", "yes", "1", "on": true
        case "false", "no", "0", "off": false
        default: nil
        }
    }

    static func durationSeconds(_ value: String?) -> Int? {
        guard let value else { return nil }
        let lower = value.lowercased()
        if lower.hasSuffix("ms") { return Int(lower.dropLast(2)).map { max(1, $0 / 1_000) } }
        if lower.hasSuffix("s") { return Int(lower.dropLast()) }
        if lower.hasSuffix("m") { return Int(lower.dropLast()).map { $0 * 60 } }
        if lower.hasSuffix("h") { return Int(lower.dropLast()).map { $0 * 3_600 } }
        return Int(lower)
    }

    static func issue(_ severity: ProfileImportIssue.Severity, _ line: SourceLine, _ message: String) -> ProfileImportIssue {
        .init(severity: severity, location: "第 \(line.number) 行", message: message)
    }
}

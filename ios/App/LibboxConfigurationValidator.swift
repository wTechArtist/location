import Foundation

#if canImport(Libbox)
import Libbox
#endif

enum LibboxConfigurationValidator {
    static func validate(_ configuration: Data) throws {
        guard let text = String(data: configuration, encoding: .utf8), !text.isEmpty else {
            throw LibboxConfigurationValidationError.invalidText
        }

        #if canImport(Libbox)
        var validationError: NSError?
        let accepted = LibboxCheckConfig(text, &validationError)
        if let validationError { throw validationError }
        guard accepted else { throw LibboxConfigurationValidationError.rejectedWithoutReason }
        #else
        throw LibboxConfigurationValidationError.libboxUnavailable
        #endif
    }
}

enum LibboxConfigurationValidationError: Error, LocalizedError {
    case invalidText
    case libboxUnavailable
    case rejectedWithoutReason

    var errorDescription: String? {
        switch self {
        case .invalidText: "配置不是有效的 UTF-8 文本。"
        case .libboxUnavailable: "缺少 Libbox，不能对代理配置做内核级校验。"
        case .rejectedWithoutReason: "Libbox 拒绝了配置，但没有返回具体原因。"
        }
    }
}

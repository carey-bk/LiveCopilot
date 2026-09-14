import Foundation

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system, english, simplifiedChinese
    var id: String { rawValue }
    var usesChinese: Bool {
        switch self {
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") == true
        case .english: return false
        case .simplifiedChinese: return true
        }
    }
    var locale: Locale { Locale(identifier: usesChinese ? "zh-Hans" : "en") }
}

enum AppBackground: String, Codable, CaseIterable, Identifiable {
    case glass, frosted, white
    var id: String { rawValue }
    var usesLightAppearance: Bool { self != .glass }
    var label: String {
        switch self {
        case .glass: return "Translucent glass"
        case .frosted: return "Soft frosted"
        case .white: return "Solid white"
        }
    }
    var detail: String {
        switch self {
        case .glass: return "Translucent glass lets more of your desktop show through."
        case .frosted: return "Soft frosted keeps a hint of the background with a light veil for clearer text."
        case .white: return "Solid white keeps dark text readable over any wallpaper."
        }
    }
}

enum ReasoningService: String, Codable, CaseIterable, Identifiable {
    case sharedOpenAI, separateOpenAI, deepSeek, compatible
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sharedOpenAI: return "Use Live service's OpenAI"
        case .separateOpenAI: return "OpenAI · separate key"
        case .deepSeek: return "DeepSeek"
        case .compatible: return "OpenAI-compatible"
        }
    }
}

/// Persist identity only; secret bytes never belong in settings or URLs.
struct CredentialReference: Equatable, Sendable {
    let service: String
    var accountSuffix = ""
    var account: String { NSUserName() + accountSuffix }
    static let live = Self(service: "LiveCopilot-OpenAI")
    static let separateOpenAI = Self(service: "LiveCopilot-Reasoning-OpenAI")
    static let deepSeek = Self(service: "LiveCopilot-Reasoning-DeepSeek")
}

extension AppSettings {
    var analysisModel: String {
        switch reasoningService {
        case .sharedOpenAI, .separateOpenAI: return reasoningModel
        case .deepSeek: return deepSeekModel
        case .compatible: return compatibleModel
        }
    }
    func analysisCredentialReference() throws -> CredentialReference {
        switch reasoningService {
        case .sharedOpenAI: return .live
        case .separateOpenAI: return .separateOpenAI
        case .deepSeek: return .deepSeek
        case .compatible:
            // Editing a destination cannot silently reuse the previous host's key.
            return CredentialReference(service: "LiveCopilot-Reasoning-Compatible", accountSuffix: "|" + (try compatibleEndpoint()).absoluteString)
        }
    }
    func compatibleEndpoint() throws -> URL {
        try ServiceEndpoint.make(baseURL: compatibleBaseURL, path: compatiblePath)
    }
}

enum ServiceEndpoint {
    static func make(baseURL: String, path: String) throws -> URL {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = path.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
        guard var c = URLComponents(string: base), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, !path.isEmpty,
              !path.contains("://"), !path.contains("?"), !path.contains("#"),
              !path.split(separator: "/").contains("..") else {
            throw CopilotError.message("Enter an HTTPS base URL and API path without credentials, query parameters or fragments.")
        }
        c.scheme = "https"; c.host = host.lowercased()
        if c.port == 443 { c.port = nil }
        c.path = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        c.path = "/" + (c.path.isEmpty ? path : c.path + "/" + path)
        guard let url = c.url else { throw CopilotError.message("Invalid analysis service URL.") }
        return url
    }
}

import Foundation
import Security
import LocalAuthentication

/// macOS credential storage. Secret bytes never enter diagnostics, files or command arguments.
enum KeychainStore {
    // The login (file-based) Keychain does not consistently honor LAContext's UI flag.
    // Serialize our Security calls while changing its process-wide interaction policy.
    private static let accessLock = NSLock()
    private static func access<T>(interactive: Bool, _ operation: () throws -> T) throws -> T {
        try accessLock.withLock {
            var allowed: DarwinBoolean = true
            if !interactive {
                let status = SecKeychainGetUserInteractionAllowed(&allowed)
                guard status == errSecSuccess else { throw keychainError(status) }
                let setStatus = SecKeychainSetUserInteractionAllowed(false)
                guard setStatus == errSecSuccess else { throw keychainError(setStatus) }
            }
            defer { if !interactive { SecKeychainSetUserInteractionAllowed(allowed.boolValue) } }
            return try operation()
        }
    }
    static let service = "LiveCopilot-OpenAI"
    static var account: String { NSUserName() }
    private static func query(service: String = service, account: String = account) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func save(_ key: String, service: String = service, account: String = account, interactive: Bool = true) throws {
        try access(interactive: interactive) {
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw CopilotError.message("API key cannot be empty.") }
            let query = query(service: service, account: account)
            let changes = [kSecValueData as String: Data(key.utf8)]
            var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
            if status == errSecItemNotFound {
                var insert = query
                insert[kSecValueData as String] = Data(key.utf8)
                insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(insert as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw keychainError(status) }
        }
    }
    static func read(service: String = service, account: String = account, interactive: Bool = true) throws -> String? {
        try access(interactive: interactive) {
            var query = query(service: service, account: account)
            if !interactive {
                let context = LAContext()
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext as String] = context
            }
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw keychainError(status) }
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
            return key
        }
    }
    static func load() -> String? { try? read() }
    static func resolve() throws -> String? {
        do {
            if let key = try read() { return key }
        } catch {
            if let fallback = environmentKey { return fallback }
            throw error
        }
        return environmentKey
    }
    private static var environmentKey: String? {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }
    static func clear(service: String = service, account: String = account) throws {
        try access(interactive: true) {
            let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
        }
    }
    private static func keychainError(_ status: OSStatus) -> Error {
        KeychainAccessError(status: status)
    }
}

struct KeychainAccessError: Error, LocalizedError {
    let status: OSStatus
    var needsAuthorization: Bool {
        [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecInteractionRequired].contains(status)
    }
    var errorDescription: String? {
        "Keychain access failed (\(status)). Unlock your login Keychain and allow LiveCopilot access to the selected service credential."
    }
}

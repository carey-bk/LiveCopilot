import Foundation

/// Where feedback goes. The website's `support.json` can change the address without a new
/// release; if it cannot be read, the built-in address is used.
enum SupportContact {
    static let defaultEmail = "carey_usyd@outlook.com"
    static let configURL = URL(string: "https://carey-bk.github.io/LiveCopilot/support.json")!

    static func isValid(_ address: String) -> Bool {
        address.count <= 254 && address.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }

    /// The address in a `support.json` document, if it is present and well formed.
    static func email(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = (object["feedbackEmail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              isValid(value) else { return nil }
        return value
    }

    /// The website's address when it answers within five seconds, otherwise the built-in one.
    static func resolve(session: URLSession = .shared) async -> String {
        var request = URLRequest(url: configURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4096,
              let address = email(from: data) else { return defaultEmail }
        return address
    }
}

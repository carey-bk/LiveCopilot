import Foundation

/// Zipformer has uppercase-only English tokens. Deterministic display cleanup; no model call.
enum TranscriptCasing {
    static func format(_ text: String, terms: [String] = []) -> String {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) && $0.isASCII }
        guard !letters.isEmpty, !letters.contains(where: { CharacterSet.lowercaseLetters.contains($0) }) else { return text }
        var result = text.lowercased()
        var names = ["AI", "API", "SQL", "HTTP", "HTTPS", "URL", "JSON", "HTML", "CSS", "CPU", "GPU", "RAM", "SDK", "UI", "UX", "USB", "TCP", "IP", "DNS", "LLM", "GPT", "iOS", "macOS", "GitHub", "OpenAI", "ChatGPT", "Python", "JavaScript", "TypeScript", "SQL", "I", "I'm", "I've", "I'll", "I'd"]
        names.append(contentsOf: terms.filter { !$0.isEmpty })
        // Longer multiword names first. Match complete words, never substrings of another word.
        for name in names.sorted(by: { $0.count > $1.count }) {
            let pattern = "(?i)(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: NSRegularExpression.escapedTemplate(for: name))
        }
        // Only capitalize sentence starts; keep established mixed-case brand names intact.
        let regex = try! NSRegularExpression(pattern: "(^|[.!?。！？]\\s+)([A-Za-z]+)")
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range(at: 2), in: result) else { continue }
            let word = String(result[range])
            if word != word.lowercased() || names.contains(where: { $0 == word }) { continue }
            result.replaceSubrange(range, with: word.prefix(1).uppercased() + word.dropFirst())
        }
        return result
    }
}

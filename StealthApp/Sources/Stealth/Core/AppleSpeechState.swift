import Foundation

enum AppleSpeechLanguage: String, Codable, CaseIterable, Identifiable {
    case chinese = "zh_CN", english = "en_US"
    var id: String { rawValue }
    var label: String { self == .chinese ? "Chinese (Mandarin)" : "English (US)" }
}

/// Keep revisable time ranges separate from committed speech. Apple may finalize
/// only the beginning of an earlier preview, then revise the remaining range.
struct SpeechPreviewState {
    struct Part: Equatable { let startMS: Int; let endMS: Int; let text: String }
    private(set) var committedThrough = -1
    private var parts: [Part] = []
    var preview: String { parts.sorted { $0.startMS < $1.startMS }.map(\.text).joined(separator: " ") }
    mutating func accept(startMS: Int, endMS: Int, text: String, final: Bool) -> Part? {
        guard endMS > committedThrough, endMS >= startMS else { return nil }
        parts.removeAll { $0.startMS < endMS && $0.endMS > startMS || $0.startMS == startMS }
        let part = Part(startMS: max(startMS, committedThrough), endMS: endMS, text: text)
        if final {
            committedThrough = endMS
            parts.removeAll { $0.endMS <= endMS }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : part
        }
        if !text.isEmpty { parts.append(part) }
        return nil
    }
}

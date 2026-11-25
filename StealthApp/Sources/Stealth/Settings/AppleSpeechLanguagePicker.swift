import SwiftUI

/// Shared by Settings and setup: Apple's on-device languages grouped by family, limited to the
/// ones this Mac supports. The current choice always stays listed.
struct AppleSpeechLanguagePicker: View {
    @Binding var language: AppleSpeechLanguage
    @ObservedObject var manager: AppleSpeechManager
    let interfaceLanguage: AppLanguage
    var title: String
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, interfaceLanguage) }
    private func name(_ item: AppleSpeechLanguage) -> String { b(item.names.en, item.names.zh) }
    private func header(_ group: AppleSpeechLanguage.Group) -> String {
        switch group {
        case .chinese: return b("Chinese", "中文")
        case .english: return b("English", "英语")
        case .other: return b("Other languages", "其他语言")
        case .india: return b("Languages of India", "印度语言")
        }
    }
    private func offered(_ group: AppleSpeechLanguage.Group) -> [AppleSpeechLanguage] {
        AppleSpeechLanguage.allCases.filter { $0.group == group && (manager.supported?.contains($0) ?? true || $0 == language) }
    }
    var body: some View {
        Picker(title, selection: $language) {
            ForEach(AppleSpeechLanguage.Group.allCases, id: \.self) { group in
                let items = offered(group)
                if !items.isEmpty {
                    Section(header(group)) {
                        ForEach(items) { Text(name($0)).tag($0) }
                    }
                }
            }
        }
        .task { await manager.loadSupported() }
    }
}

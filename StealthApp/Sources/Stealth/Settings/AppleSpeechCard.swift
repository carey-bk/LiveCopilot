import SwiftUI

struct AppleSpeechCard: View {
    @ObservedObject var manager: AppleSpeechManager
    @Binding var language: AppleSpeechLanguage
    let interfaceLanguage: AppLanguage
    let locked: Bool
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, interfaceLanguage) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(b("Recognition language", "识别语言"), selection: $language) {
                Text(b("Mandarin Chinese", "普通话")).tag(AppleSpeechLanguage.chinese)
                Text(b("English (US)", "英语（美国）")).tag(AppleSpeechLanguage.english)
            }.disabled(locked || manager.busy)
            Label(L10n.text(manager.message, language: interfaceLanguage), systemImage: manager.installed ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(manager.installed ? .green : .secondary).font(.callout)
            HStack {
                if manager.busy { ProgressView().controlSize(.small); Button(b("Cancel", "取消")) { manager.cancel() } }
                else if !manager.installed {
                    Button(b("Download language", "下载语言资源")) { manager.install(language) }.disabled(locked || !manager.available)
                }
                Button(b("Refresh status", "刷新状态")) { Task { await manager.refresh(language) } }.disabled(manager.busy)
            }
            Text(b("Local / no API fee. Apple manages the model files; after downloading, speech recognition runs offline. This language setting is independent of the interface language.", "本地 / 无 API 费用。模型文件由 Apple 管理，下载后语音识别离线运行。识别语言与界面语言分别设置。")).font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .task(id: language) { await manager.refresh(language) }
    }
}

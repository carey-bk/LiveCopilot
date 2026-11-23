import SwiftUI

struct AppleSpeechCard: View {
    @ObservedObject var manager: AppleSpeechManager
    @Binding var language: AppleSpeechLanguage
    let interfaceLanguage: AppLanguage
    let locked: Bool
    var permitsDownload = true
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, interfaceLanguage) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(b("Apple local speech recognition", "Apple 本机语音识别")).font(.headline)
            Text(b("Built-in macOS speech recognition with real-time transcription and offline operation. Suitable for meetings and interviews primarily in Chinese or English.", "使用 macOS 内置语音识别能力，支持实时转写和离线运行。适合以中文或英文为主的会议与面试。"))
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(b("Recognition language", "识别语言")).font(.callout).foregroundStyle(.secondary)
                    Picker(b("Recognition language", "识别语言"), selection: $language) {
                        Text(b("Mandarin Chinese", "普通话")).tag(AppleSpeechLanguage.chinese)
                        Text(b("English (US)", "英语（美国）")).tag(AppleSpeechLanguage.english)
                    }.labelsHidden().fixedSize().disabled(locked || manager.busy)
                        .accessibilityIdentifier("apple-speech-language")
                }
                Spacer(minLength: 0)
                Label(manager.installed && !manager.busy ? b("Ready · available offline", "已就绪 · 离线可用") : L10n.text(manager.message, language: interfaceLanguage),
                      systemImage: manager.installed && !manager.busy ? "checkmark.circle" : "arrow.down.circle")
                    .font(.callout).foregroundStyle(manager.installed && !manager.busy ? LC.success : Color.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(manager.installed && !manager.busy ? LC.success.opacity(0.1) : Color.secondary.opacity(0.08), in: Capsule())
            }
            Label(b("Only the selected language is recognized; automatic Chinese/English switching is not supported. Use Zipformer for mixed-language speech.", "当前仅识别所选语言，不支持自动切换中英文。混合语言场景建议使用 Zipformer。"), systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Text(b("Models are managed by macOS. No API Key or speech recognition API fees are required.", "模型由 macOS 管理，无需 API Key，不产生语音识别 API 费用。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Apple SpeechAnalyzer · macOS 26+").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if manager.busy { ProgressView().controlSize(.small); Button(b("Cancel", "取消")) { manager.cancel() } }
                else if !manager.installed {
                    Button(b("Download language", "下载语言资源")) { manager.install(language) }.disabled(locked || !manager.available || !permitsDownload)
                }
                Button(b("Check again", "重新检测")) { Task { await manager.refresh(language) } }.disabled(manager.busy)
            }
        }.lcCard()
            .task(id: language) { await manager.refresh(language) }
    }
}

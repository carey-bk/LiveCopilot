import SwiftUI

/// Shared by setup and settings so language guidance stays identical in both places.
struct LiveSpeechLanguagePicker: View {
    @Binding var language: LiveSpeechLanguage
    let interfaceLanguage: AppLanguage
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, interfaceLanguage) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(b("Recognition language preference", "识别语言偏好"), selection: $language) {
                Text(b("Chinese first", "中文优先")).tag(LiveSpeechLanguage.chinese)
                Text(b("English first", "英文优先")).tag(LiveSpeechLanguage.english)
                Text(b("Chinese + English", "中英混合")).tag(LiveSpeechLanguage.mixed)
                Text(b("Any language (no guidance)", "不限语言（不作引导）")).tag(LiveSpeechLanguage.unrestricted)
            }.accessibilityIdentifier("live-speech-language")
            Text(b("The first three options guide GPT-Live-1 without locking its language. Any language sends no language hint. Changes apply when you next start listening.", "前三项提供语言偏好，不会锁定语言。“不限语言”不发送语言提示，由模型根据音频判断，下次开始监听时生效。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

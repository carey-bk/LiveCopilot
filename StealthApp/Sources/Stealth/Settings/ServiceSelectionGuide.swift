import SwiftUI

/// Shared by onboarding and settings so provider choices have the same explanation.
struct SpeechSelectionGuide: View {
    let language: AppLanguage
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(b("Choose for your conversation", "按对话语言选择")).font(.callout.weight(.medium))
            Text(b("Chinese/English mixed or switching often: Paraformer. Runs on this Mac with no speech API fee.",
                   "中英混说或频繁切换：Paraformer。本机处理，无语音 API 费用。"))
            Text(b("Mostly Mandarin or mostly English: Apple. Select that language before listening; it does not switch automatically.",
                   "主要说普通话或英语：Apple。开始前选择对应识别语言，不会自动切换。"))
            Text(b("More languages: OpenAI cloud. Requires internet; audio is uploaded and billed by usage.",
                   "更多语言：OpenAI 云端。需要联网，音频上传并按用量计费。"))
            Text(b("Recognition language controls transcription. Answer language controls the generated reply.",
                   "识别语言影响转写，回答语言影响生成的文字；两者分别设置。"))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("speech-selection-guide")
    }
}

struct OpenAIAnalysisModelHint: View {
    @Binding var settings: AppSettings
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, settings.language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(b("Default: GPT-6.1 Sol with low reasoning effort. Your saved model choice is kept.",
                   "默认推荐 GPT-6.1 Sol，低推理强度。已保存的模型选择会保留。"))
                .font(.caption).foregroundStyle(.secondary)
            if settings.reasoningModel != AppSettings.defaultReasoningModel {
                Button(b("Use GPT-6.1 Sol · Low", "使用 GPT-6.1 Sol · 低推理强度")) {
                    var updated = settings
                    updated.reasoningModel = AppSettings.defaultReasoningModel
                    updated.reasoningEffort = "low"
                    settings = updated
                }.accessibilityIdentifier("use-default-openai-model")
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

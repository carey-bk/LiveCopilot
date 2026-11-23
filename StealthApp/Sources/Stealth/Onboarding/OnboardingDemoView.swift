import SwiftUI

/// The production floating-window views, fed only by isolated, scripted sample data.
struct OnboardingWorkflowDemo: View {
    let language: AppLanguage
    @Binding var automatic: Bool
    let editable: Bool
    let reduceMotion: Bool
    @StateObject private var preview: AppCoordinator
    @StateObject private var answer = SuggestionStore()
    private let preferences: UserDefaults
    @State private var tick = 0
    init(language: AppLanguage, automatic: Binding<Bool>, editable: Bool, reduceMotion: Bool) {
        self.language = language
        _automatic = automatic
        self.editable = editable
        self.reduceMotion = reduceMotion
        let defaults = UserDefaults(suiteName: "livecopilot.workflow-demo")!
        preferences = defaults
        _preview = StateObject(wrappedValue: AppCoordinator(mock: true, emitMockConversation: false, mockDefaults: defaults,
            mockKnowledgeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("livecopilot-workflow-demo")))
    }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, language) }
    private var question: String { b("How would you introduce a project you worked on?", "你会怎样介绍自己做过的一个项目？") }
    private var response: String { b("I built a search index for our project. It cut lookup time in half and made the team's daily work easier. [S1]", "我负责项目里的搜索功能。我建立了**检索索引**，将查询耗时**缩短一半**，让团队更快找到需要的记录。[S1]") }
    private var stage: Int { reduceMotion ? 3 : min(3, tick / 7) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geometry in
                let record = AppCoordinator.AnswerRecord(id: UUID(), questionID: UUID(), automatic: automatic,
                                                        createdAt: Date(timeIntervalSince1970: 0), store: answer, viewed: true)
                OverlayView(coordinator: preview, demonstrationAnswer: record, transcriptPreferences: preferences)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false).accessibilityLabel(b("Floating window workflow example", "悬浮窗工作流程示例"))
            }

        }.overlay(alignment: .bottomLeading) {
            Text(b("Sample conversation · no recording or API requests", "示例对话 · 不录音，不调用 API"))
                .font(.caption).foregroundStyle(.secondary).offset(y: 26)
        }.task(id: language) {
            preview.settings.background = .white
            preview.settings.language = language
            preview.settings.answerFontSize = 15
            preview.settings.transcriptFontSize = 14
            preview.onboarding.dismissTips()
            updateSample()
        }.task(id: reduceMotion) {
            if reduceMotion { updateSample(); return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(400))
                    tick = (tick + 1) % 38
                    updateSample()
                }
            } catch {}
        }.onChange(of: automatic) { _, _ in updateSample() }
    }
    private func updateSample() {
        preview.settings.automaticSuggestions = automatic
        preview.statusMessage = [b("Listening · sample conversation", "正在聆听 · 示例对话"),
                                 automatic ? b("Jev Mode · complete question detected", "Jev Mode · 已识别完整提问") : b("Manual question submitted", "手动提交问题"),
                                 b("Personal knowledge base · finding evidence", "个人知识库 · 正在寻找依据"),
                                 b("Preparing an answer suggestion", "正在准备回答建议")][stage]
        preview.transcript.clear()
        let text = stage == 0 ? String(question.prefix(max(1, question.count * (tick + 1) / 7))) : question
        preview.transcript.commit(text, speaker: .them)
        answer.reset()
        answer.prepare(question: stage == 0 ? text : question)
        if stage >= 2 {
            answer.begin(question: question)
            answer.sources = [RetrievedSource(chunk: SourceChunk(id: "demo-project", documentID: "demo", documentName: b("Project notes.pdf", "项目复盘.pdf"), ordinal: 0, page: 1,
                text: b("The search index cut lookup time in half.", "建立检索索引后，查询耗时减半。"), vector: [], embeddingModel: "demo"), score: 1)]
            if stage == 2 { answer.warning = b("Personal knowledge base · Project notes matched", "个人知识库 · 已匹配项目复盘") }
        }
        if stage >= 3 {
            let count = reduceMotion ? response.count : min(response.count, response.count * max(1, tick - 20) / 7)
            answer.appendDelta(String(response.prefix(count)))
            if count == response.count { answer.finish() }
        }
    }
}

struct OnboardingModePreview: View {
    let language: AppLanguage
    let typing: Bool
    let remote: Bool
    let microphone: Bool
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(typing ? b("Manual input", "手动输入") : remote ? b("Remote meeting", "远程会议") : b("In-person conversation", "现场交流"),
                  systemImage: typing ? "keyboard" : remote ? "headphones" : "mic").font(.headline)
            Text(typing ? b("Type a question to get suggestions without recording.", "直接输入问题，无需录音也能获取回答建议。") :
                    remote ? (microphone ? b("Online meetings and interviews · system audio and microphone", "线上会议或远程面试 · 系统音频与麦克风") : b("Online meetings and interviews · system audio only", "线上会议或远程面试 · 仅系统音频")) :
                    b("One microphone captures the room without identifying individual speakers.", "通过麦克风记录现场对话，不区分说话人。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(typing ? b("How can I explain a proposal clearly?", "如何清楚地介绍一个方案？") :
                    remote ? b("What is the biggest risk in this proposal?", "你认为这个方案最大的风险是什么？") :
                    b("Tell me about a project you worked on.", "介绍一下你做过的项目吧。"))
                .font(.body.weight(.medium)).padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(typing ? 0.16 : 0)))
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.82), in: RoundedRectangle(cornerRadius: LC.Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LC.Radius.panel, style: .continuous).strokeBorder(LC.hairline))
    }
}

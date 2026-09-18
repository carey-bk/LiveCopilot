import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var hotkeys: HotkeyStore
    @State private var page = SettingsPage.general
    @State private var serviceRole = 0
    @State private var baseURL = ""
    @State private var apiPath = ""
    @State private var customModel = ""
    @State private var connectionMessage = ""
    @State private var showOpenAIKey = false
    init(coordinator: AppCoordinator) { self.coordinator = coordinator; hotkeys = coordinator.hotkeys }
    private func t(_ text: String) -> String { L10n.text(text, language: coordinator.settings.language) }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private var locked: Bool { coordinator.isRunning || coordinator.isTransitioning }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                AppBrandTitle(iconSize: 26, titleSize: 18)
                    .padding(.horizontal, 16).padding(.top, 22)
                VStack(spacing: 5) {
                    ForEach(SettingsPage.allCases) { item in
                        Button { page = item } label: {
                            Label(t(item.rawValue), systemImage: item.icon)
                                .font(.system(size: 14, weight: page == item ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
                                .background(page == item ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("settings-" + item.id)
                    }
                }.padding(.horizontal, 10)
                Spacer()
                Text(coordinator.isMock ? t("MOCK — no API calls") : AppInfo.display)
                    .font(.caption2).foregroundStyle(.secondary).padding(16)
            }.frame(width: 180).background(.thinMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                Text(t(page.rawValue)).font(.system(size: 24, weight: .semibold))
                switch page {
                case .general: ScrollView { general }
                case .services: ScrollView { services }
                case .knowledge: knowledge
                case .shortcuts: shortcuts
                case .about: ScrollView { about }
                }
            }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 820, idealWidth: 860, minHeight: 610, idealHeight: 680)
        .background { WindowBackgroundView(style: coordinator.settings.background) }
        .preferredColorScheme(coordinator.settings.background.usesLightAppearance ? .light : nil)
        .environment(\.locale, coordinator.settings.language.locale)
        .onAppear { loadCustomDraft() }
        .sheet(isPresented: $showOpenAIKey) {
            VStack(alignment: .leading, spacing: 18) {
                Text(t("Manage OpenAI credential")).font(.title2)
                CredentialEditor(coordinator: coordinator, analysis: false)
                Button(t("Done")) { showOpenAIKey = false }
            }.padding(24).frame(width: 540)
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 24) {
            AppBrandTitle(iconSize: 64, titleSize: 28)
            Text(AppInfo.display).foregroundStyle(.secondary).textSelection(.enabled)
            Text(b("A native macOS conversation copilot. Listen, find relevant knowledge, and get words you can say aloud.",
                   "原生 macOS 对话助手。听取对话、查找相关资料，生成可以直接说出口的回答。"))
                .font(.body).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 18) {
                Link(destination: URL(string: "https://github.com/carey-bk")!) {
                    Label(b("Author on GitHub", "作者 GitHub 主页"), systemImage: "person.crop.circle")
                }.accessibilityIdentifier("about-author")
                Link(destination: URL(string: "https://github.com/carey-bk/LiveCopilot")!) {
                    Label(b("LiveCopilot on GitHub", "LiveCopilot 项目仓库"), systemImage: "chevron.left.forwardslash.chevron.right")
                }.accessibilityIdentifier("about-repository")
                Link(destination: URL(string: coordinator.settings.language.usesChinese
                                       ? "https://carey-bk.github.io/LiveCopilot/"
                                       : "https://carey-bk.github.io/LiveCopilot/en/")!) {
                    Label(b("Product guide · 中文 / English", "使用介绍 · 中文 / English"), systemImage: "globe")
                }.accessibilityIdentifier("about-guide")
            }.buttonStyle(.link)
            Divider()
            Text(b("Open source under the MIT license. Built on Stealth's native macOS foundation.",
                   "基于 Stealth 原生 macOS 架构开发，采用 MIT 开源许可。"))
                .font(.callout).foregroundStyle(.secondary)
            Link("Stealth · vortechron", destination: URL(string: "https://github.com/vortechron/stealth")!)
                .font(.callout)
        }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(t("Interface language"), selection: $coordinator.settings.language) {
                        Text(t("Follow system")).tag(AppLanguage.system)
                        Text("English").tag(AppLanguage.english)
                        Text("简体中文").tag(AppLanguage.simplifiedChinese)
                    }.accessibilityIdentifier("interface-language")
                    Text(t("Changes apply immediately. Answers follow the language of your question.")).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Picker(t("Window background"), selection: $coordinator.settings.background) {
                        ForEach(AppBackground.allCases) { background in
                            Text(t(background.label)).tag(background)
                        }
                    }.pickerStyle(.segmented).accessibilityIdentifier("window-background")
                    Text(t(coordinator.settings.background.detail)).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    fontSizeControl(b("Transcript text", "流式识别区字号"), value: $coordinator.settings.transcriptFontSize, identifier: "transcript-font-size",
                                    preview: b("What was your role in this project?", "你在这个项目中具体负责什么？"))
                    fontSizeControl(b("Answer text", "回答区字号"), value: $coordinator.settings.answerFontSize, identifier: "answer-font-size",
                                    preview: b("I would start with the goal, then explain the approach.", "我会先说明目标，再介绍具体的方法。"))
                    Text(b("Text sizes are independent and take effect immediately. The window reflows; longer content scrolls.", "两处字号独立保存、即时生效；窗口会重新排版，较长的内容可滚动阅读。")).font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            } label: { Label(t("Language & appearance"), systemImage: "paintpalette") }
            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(t("Fit window height to content"), isOn: $coordinator.settings.overlayAutoHeight)
                        .accessibilityIdentifier("overlay-auto-height")
                    Text(t("Stay compact when empty, grow with captions and answers, then scroll at the screen limit. Drag a vertical edge to switch to manual sizing.")).font(.caption).foregroundStyle(.secondary)
                    Toggle(t("Hide at the right screen edge"), isOn: $coordinator.settings.overlayEdgeHide)
                        .accessibilityIdentifier("overlay-edge-hide")
                    Text(t("Starts hidden. Hover at the right edge to reveal; move away to tuck it back. Pin the window or press ⌥H to keep it within reach.")).font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            } label: { Label(t("Floating window"), systemImage: "rectangle.righthalf.inset.filled") }
            SettingsSection {
                VStack(alignment: .leading, spacing: 14) {
                    Picker(t("Operating mode"), selection: $coordinator.settings.mode) {
                        ForEach(OperatingMode.allCases) { Text(t($0.rawValue)).tag($0) }
                    }.disabled(locked)
                    Text(b("Remote Meeting separates system audio (Them) from your microphone (You); In-Person uses one room microphone, without speaker diarization.", "远程会议：系统音频标为对方、麦克风标为我；现场/答辩：仅用房间麦克风，不区分具体说话人。")).font(.caption).foregroundStyle(.secondary)
                    Picker(t("Scenario"), selection: $coordinator.settings.scenario) {
                        ForEach(ScenarioProfile.allCases) { Text(t($0.rawValue)).tag($0) }
                    }.disabled(locked)
                    Text(b("Interview: personal experience and talking points. Meeting: decisions and next actions. Defense: methods, evidence and limitations. These change answer instructions and automatic-suggestion cooldown, not ASR accuracy.", "面试：个人经历与表达要点；会议：决策与后续行动；答辩：方法、证据与局限。场景改变回答提示词和自动建议冷却时间，不改变语音识别准确率。")).font(.caption).foregroundStyle(.secondary)
                    if locked { Text(t("Stop listening to change mode or scenario.")).font(.caption).foregroundStyle(.secondary) }
                    Toggle(t("Automatic suggestions for meaningful questions"), isOn: $coordinator.settings.automaticSuggestions)
                }.padding(10)
            } label: { Label(t("Conversation"), systemImage: "waveform") }
            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(t("Recap"), isOn: $coordinator.settings.recapEnabled)
                        .accessibilityIdentifier("enable-recap")
                    Text(t("Summarize recent topics, decisions and unresolved questions, including action items and owners when mentioned."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Toggle(t("Follow-up"), isOn: $coordinator.settings.followUpEnabled)
                        .accessibilityIdentifier("enable-follow-up")
                    Text(.init(t("Suggest **one question you can ask next** to clarify information or explore the topic, phrased naturally to say aloud.")))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(t("Turning a tool off hides its button and disables its shortcut."))
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(10)
            } label: { Label(t("Conversation tools"), systemImage: "list.bullet.rectangle") }
            CapturePermissionCard(language: coordinator.settings.language)
            VStack(alignment: .leading, spacing: 7) {
                Label(t("Capture exclusion"), systemImage: "eye.slash").font(.headline)
                Toggle(t("Hide overlay from screenshots and screen sharing"), isOn: $coordinator.settings.excludeOverlayFromCapture)
                    .accessibilityIdentifier("exclude-overlay-capture")
                Text(t("Turn this off to capture the overlay. Settings and history can always be captured. Exclusion depends on macOS and your capture app.")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.bottom, 4)
    }
    private var services: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker(t("Service role"), selection: $serviceRole) {
                Text(t("Live service")).tag(0)
                Text(t("Knowledge service")).tag(1)
                Text(t("Analysis service")).tag(2)
            }.pickerStyle(.segmented).accessibilityIdentifier("service-role")
            if serviceRole == 2 { analysisService } else if serviceRole == 1 { embeddingService } else { liveService }
        }.padding(.bottom, 4)
    }
    private var liveService: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker(t("Listening provider"), selection: $coordinator.settings.listeningService) {
                ForEach(ListeningService.allCases) { service in
                    Text(service == .openAI && coordinator.settings.liveModel == "gpt-live-1"
                         ? b("GPT-Live-1 · $0.05/min/session, cloud", "GPT-Live-1 · $0.05/分钟/路，云端")
                         : ServiceGuide.listening(service, language: coordinator.settings.language)).tag(service)
                }
            }.disabled(locked).accessibilityIdentifier("listening-provider")
            if coordinator.settings.listeningService == .apple {
                Text(b("SpeechAnalyzer + SpeechTranscriber: offline streaming captions with revisable previews. Apple manages language downloads and inference. Requires macOS 26 and supported hardware; choose Mandarin or English before listening. This option does not automatically switch languages.", "SpeechAnalyzer + SpeechTranscriber：离线流式转写，预览文字会修正。语言模型与推理由 macOS 管理，需要 macOS 26 和受支持硬件；开始前选择普通话或英语，不自动切换语言。")).font(.callout).foregroundStyle(.secondary)
                AppleSpeechCard(manager: coordinator.appleSpeech, language: $coordinator.settings.appleSpeechLanguage, interfaceLanguage: coordinator.settings.language, locked: locked)
                Text(b("Like FunASR, automatic suggestions use local question rules plus a pause. Recognition speed and accuracy depend on your language, microphone and vocabulary; neither engine is always better.", "与 FunASR 一样，自动建议通过本地提问规则与停顿触发。速度和准确率取决于语言、麦克风及术语，没有在所有场景都更好的引擎。")).font(.caption).foregroundStyle(.secondary)
            } else if let kind = coordinator.settings.listeningService.localModel {
                Text(t("Audio stays on this Mac. Chinese and English captions update while you speak. Preview text can change; completed sentences are used for automatic suggestions.")).font(.callout).foregroundStyle(.secondary)
                LocalModelCard(manager: coordinator.localModels, kind: kind, language: coordinator.settings.language, locked: locked)
                Text(b("English terminology can be misrecognized. For English-heavy conversations, compare Apple English or GPT-Live-1 on your own audio.", "英文术语可能误识别。英文较多时，可用自己的音频对比 Apple 英语识别或 GPT-Live-1。")).font(.caption).foregroundStyle(.secondary)
                Text(t("Automatic suggestions use conservative local question rules. Pauses alone do not trigger analysis; use the shortcut for missed questions.")).font(.caption).foregroundStyle(.secondary)
                localCost
            } else {
                Label("OpenAI", systemImage: "waveform").font(.title3.bold())
                Text(t("Audio is sent to OpenAI Live for transcription and semantic question detection.")).font(.callout).foregroundStyle(.secondary)
                CredentialEditor(coordinator: coordinator, analysis: false)
                modelField("Live model", value: $coordinator.settings.liveModel).disabled(locked)
                priceNote(ServiceGuide.livePrice(coordinator.settings.liveModel, language: coordinator.settings.language), url: "https://developers.openai.com/api/docs/models/gpt-live-1")
            }
        }
    }
    private var embeddingService: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker(t("Embedding provider"), selection: $coordinator.settings.embeddingService) {
                ForEach(EmbeddingService.allCases) { service in
                    Text(t(service.label) + (service == .local ? b(" · local/free", " · 本地/免费") : b(" · billed per token", " · 按 token 计费"))).tag(service)
                }
            }.disabled(coordinator.isIndexing || coordinator.suggestion.isLoading).accessibilityIdentifier("embedding-provider")
            if coordinator.settings.embeddingService == .local {
                Text(t("Document and query embeddings run on this Mac. No OpenAI key or network is needed after downloading the model.")).font(.callout).foregroundStyle(.secondary)
                LocalModelCard(manager: coordinator.localModels, kind: .embedding, language: coordinator.settings.language, locked: coordinator.isIndexing || coordinator.suggestion.isLoading)
            } else {
                Text(t("Extracted document text and retrieval queries are sent to OpenAI Embeddings using the shared OpenAI credential.")).font(.callout).foregroundStyle(.secondary)
                CredentialEditor(coordinator: coordinator, analysis: false)
                modelField("Embedding model", value: $coordinator.settings.embeddingModel).disabled(coordinator.isIndexing)
                Text(b("Small: lower cost. Large: larger vectors and higher cost. Validate retrieval on your own documents; BGE-M3 runs locally without an API fee.", "Small：费用更低；Large：向量更大、费用更高。检索效果需用自己的文档验证；BGE-M3 在本地运行，无 API 调用费。")).font(.caption).foregroundStyle(.secondary)
                priceNote(ServiceGuide.embeddingPrice(coordinator.settings.embeddingModel, language: coordinator.settings.language), url: "https://developers.openai.com/api/docs/pricing")
            }
            if coordinator.settings.embeddingService == .local { localCost }
            Text(t("After changing the embedding model, re-index documents. Keyword retrieval remains available for older indexes.")).font(.caption).foregroundStyle(.secondary)
            Button(t("Open knowledge library")) { page = .knowledge }
        }
    }
    private var analysisService: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker(t("Provider"), selection: $coordinator.settings.reasoningService) {
                ForEach(ReasoningService.allCases) { service in
                    Text(t(service.label) + (service == .compatible ? b(" · provider pricing", " · 服务商定价") : b(" · billed per token", " · 按 token 计费"))).tag(service)
                }
            }.accessibilityIdentifier("analysis-provider")
            Text(t("This service receives the question, relevant conversation and retrieved excerpts to generate an answer. Audio follows your listening provider selection.")).font(.callout).foregroundStyle(.secondary)
            if coordinator.settings.reasoningService == .sharedOpenAI {
                Label(t("Using the Live service credential."), systemImage: "link").font(.headline)
                CredentialStatus(coordinator: coordinator, analysis: false)
                Button(t("Manage OpenAI credential")) { showOpenAIKey = true }
            } else if coordinator.settings.reasoningService == .separateOpenAI || coordinator.settings.reasoningService == .deepSeek {
                CredentialEditor(coordinator: coordinator, analysis: true).id(coordinator.settings.reasoningService)
            }
            switch coordinator.settings.reasoningService {
            case .sharedOpenAI, .separateOpenAI:
                SettingsSection {
                    VStack(spacing: 14) {
                        modelField("Reasoning model", value: $coordinator.settings.reasoningModel)
                        Picker(t("Reasoning effort"), selection: $coordinator.settings.reasoningEffort) {
                            Text(t("Model default")).tag(""); Text(t("Low (faster)")).tag("low")
                            Text(t("Medium")).tag("medium"); Text(t("High")).tag("high")
                        }
                    }.padding(10)
                } label: { Text("OpenAI Responses") }
            case .deepSeek:
                SettingsSection {
                    VStack(alignment: .leading, spacing: 14) {
                        modelField("Reasoning model", value: $coordinator.settings.deepSeekModel)
                        Picker(t("Reasoning effort"), selection: $coordinator.settings.deepSeekEffort) {
                            Text(t("Off")).tag("none"); Text(t("Low (faster)")).tag("low")
                            Text(t("High")).tag("high"); Text(t("Maximum")).tag("max")
                        }
                        Text("https://api.deepseek.com/chat/completions").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(10)
                } label: { Text("DeepSeek") }
            case .qwen, .glm, .kimi:
                PresetAnalysisSettings(coordinator: coordinator).id(coordinator.settings.reasoningService)
            case .compatible: customService
            }
            Text(b("Higher reasoning effort can improve complex answers but takes longer and can use more output tokens. Off disables optional thinking when the model supports it. A separate OpenAI key changes billing credentials, not the model's capability.", "更高思考强度可能改善复杂回答，但通常更慢、输出 token 更多；关闭表示不启用模型可选的思考。独立 OpenAI Key 仅改变计费凭据，不改变模型能力。")).font(.caption).foregroundStyle(.secondary)
            priceNote(ServiceGuide.analysisPrice(coordinator.settings.reasoningService, model: coordinator.settings.analysisModel, language: coordinator.settings.language),
                      url: coordinator.settings.reasoningService.pricingURL)
            Text(t("Changes apply to the next answer. Existing knowledge vectors do not need re-indexing when you change only the analysis model.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var customService: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection {
                VStack(alignment: .leading, spacing: 14) {
                    modelField("API Base URL", value: $baseURL, prompt: "https://your-provider.example/v1")
                    modelField("API path", value: $apiPath, prompt: "chat/completions")
                    modelField("Reasoning model", value: $customModel)
                    Text(t("Use an HTTPS service supporting streamed Chat Completions. The base URL and path are joined; include /v1 only once.")).font(.caption).foregroundStyle(.secondary)
                    Button(t("Save connection")) { saveCustomConnection() }
                    if !connectionMessage.isEmpty { Text(t(connectionMessage)).font(.caption).foregroundStyle(.secondary) }
                }.padding(10)
            } label: { Text(t("Connection")) }
            if (try? coordinator.settings.compatibleEndpoint()) != nil {
                CredentialEditor(coordinator: coordinator, analysis: true)
                    .id(try? coordinator.settings.analysisCredentialReference().account)
            } else {
                Text(t("Save the service address before configuring its key.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func loadCustomDraft() {
        baseURL = coordinator.settings.compatibleBaseURL; apiPath = coordinator.settings.compatiblePath; customModel = coordinator.settings.compatibleModel
    }
    private func saveCustomConnection() {
        do {
            _ = try ServiceEndpoint.make(baseURL: baseURL, path: apiPath)
            guard !customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CopilotError.message("Enter an analysis model name in Services.") }
            var settings = coordinator.settings
            settings.compatibleBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.compatiblePath = apiPath.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.compatibleModel = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
            coordinator.settings = settings
            connectionMessage = "Connection saved. Credentials are scoped to this endpoint."
        } catch { connectionMessage = error.localizedDescription }
    }
    private var localCost: some View {
        Text(b("Local/free means no API usage fee. The first model download needs a network connection and disk space; inference uses this Mac's memory and compute. Selected excerpts still go to your analysis service when requesting an answer.", "本地/免费指无 API 调用费。首次模型下载需要联网与磁盘空间，运行占用本机内存与计算资源；请求回答时，选中的文本证据仍会发送给分析服务。")).font(.caption).foregroundStyle(.secondary)
    }
    private func priceNote(_ message: String, url: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(b("Usage & price", "用量与价格"), systemImage: "creditcard").font(.headline)
            Text(message).font(.callout).textSelection(.enabled)
            if let url, let destination = URL(string: url) {
                HStack {
                    Text(b("Reference checked ", "参考信息核对于 ") + ServiceGuide.checked).font(.caption)
                    Link(b("Official pricing", "官方价格"), destination: destination).font(.caption)
                }.foregroundStyle(.secondary)
                Text(b("Published list prices are a reference, not a bill. Provider updates, taxes and account discounts may change the amount.", "公布价格供参考，不是账单估算；厂商调价、税费和账户优惠可能影响实际费用。")).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
    private func fontSizeControl(_ title: String, value: Binding<Double>, identifier: String, preview: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) pt").monospacedDigit().foregroundStyle(.secondary)
                Stepper(title, value: value, in: OverlayTypography.range, step: 1).labelsHidden()
                    .accessibilityLabel(title).accessibilityIdentifier(identifier)
            }
            Slider(value: value, in: OverlayTypography.range, step: 1)
                .accessibilityLabel(title).accessibilityIdentifier(identifier + "-slider")
            Text(preview).font(.system(size: value.wrappedValue)).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func modelField(_ title: String, value: Binding<String>, prompt: String? = nil) -> some View {
        HStack {
            Text(t(title)).frame(width: 120, alignment: .leading)
            TextField(t(title), text: value, prompt: Text(prompt ?? t(title))).textFieldStyle(.roundedBorder)
        }
    }
    private var knowledge: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Local knowledge base")).font(.headline)
            KnowledgeImportDropZone(language: coordinator.settings.language, isIndexing: coordinator.isIndexing,
                                    selectDocuments: selectDocuments, importDocuments: coordinator.importDocuments,
                                    reportError: { coordinator.knowledgeMessage = $0 })
            Text(t(coordinator.settings.embeddingService == .local
                   ? "PDF, Markdown, TXT and DOCX · parsing, embeddings and retrieval stay on this Mac. Answer generation sends selected excerpts to your analysis service."
                   : "PDF, Markdown, TXT and DOCX · original copies remain local. Indexing sends extracted text to OpenAI.")).font(.caption).foregroundStyle(.secondary)
            if coordinator.knowledgeDocuments.contains(where: { $0.embeddingModel != coordinator.settings.selectedEmbeddingIdentity }) {
                HStack {
                    Text(t("Some documents use a different embedding model. Re-index them to restore semantic retrieval.")).font(.caption).foregroundStyle(.orange)
                    Button(t("Re-index all")) { coordinator.reindexAll() }.disabled(coordinator.isIndexing)
                }
            }
            Stepper(t("Evidence chunks") + ": \(coordinator.settings.retrievalCount)", value: $coordinator.settings.retrievalCount, in: 3...8)
            Text(b("More evidence chunks provide more context but increase the analysis model's input tokens and may add irrelevant text.", "证据片段越多，分析模型可读的上下文越多，但输入 token 和无关信息也可能增加。")).font(.caption).foregroundStyle(.secondary)
            if coordinator.isIndexing { ProgressView().controlSize(.small) }
            if !coordinator.knowledgeMessage.isEmpty { Text(t(coordinator.knowledgeMessage)).font(.caption).textSelection(.enabled) }
            List {
                ForEach(coordinator.knowledgeDocuments) { document in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(document.name).font(.headline)
                        Text("\(t(document.status)) · \(document.chunkCount) \(t("chunks")) · \(document.embeddingModel)").font(.caption).foregroundStyle(.secondary)
                        if let error = document.error { Text(t(error)).font(.caption).foregroundStyle(.red) }
                        HStack {
                            Button(t("Re-index")) { coordinator.reindex(document) }
                            Button(t("Show local copy")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: document.localPath)]) }
                            Spacer()
                            Button(t("Delete"), role: .destructive) { coordinator.deleteDocument(document) }
                        }.buttonStyle(.borderless).disabled(coordinator.isIndexing)
                    }.padding(.vertical, 5).accessibilityElement(children: .contain)
                }
            }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 8))
            if coordinator.knowledgeDocuments.isEmpty { Text(t("Import a document to ground answers in your own evidence.")).foregroundStyle(.secondary) }
        }
    }
    private func selectDocuments() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentParser.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.begin { response in if response == .OK { coordinator.importDocuments(panel.urls) } }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(t("Global shortcuts")).font(.headline)
            ForEach(SuggestionMode.allCases) { mode in
                HStack {
                    Label(t(mode.label), systemImage: mode.systemImage).frame(width: 130, alignment: .leading)
                    KeyRecorderView(combo: hotkeys.combo(for: mode), language: coordinator.settings.language) { coordinator.updateHotkey($0, for: mode) }.frame(width: 140, height: 28)
                    Button(t("Reset")) { coordinator.resetHotkey(mode) }
                }.disabled(!coordinator.settings.isEnabled(mode))
                if !coordinator.settings.isEnabled(mode) {
                    Text(t("Enable this tool in General to use its shortcut.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(t("⌥H shows/hides the overlay. Click the text box to type; Return submits a question even when listening is off.")).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", services = "Services", knowledge = "Knowledge", shortcuts = "Shortcuts", about = "About"
    var id: String { rawValue.lowercased() }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .services: return "shippingbox"
        case .knowledge: return "books.vertical"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

private struct LocalModelCard: View {
    @ObservedObject var manager: LocalModelManager
    let kind: LocalModelKind
    let language: AppLanguage
    let locked: Bool
    private func t(_ text: String) -> String { L10n.text(text, language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(kind.title).font(.headline)
                    Text(t("Download size") + " · " + kind.downloadSize).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(t(manager.installed.contains(kind) ? "Installed · offline ready" : "Not downloaded"),
                      systemImage: manager.installed.contains(kind) ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.caption).foregroundStyle(manager.installed.contains(kind) ? .green : .secondary)
            }
            if manager.downloading == kind {
                HStack { ProgressView().controlSize(.small); Text(t(manager.message)).font(.caption); Spacer(); Button(t("Cancel")) { manager.cancel() } }
            } else {
                Button(t(manager.installed.contains(kind) ? "Download again" : "Download model")) { manager.install(kind) }
                    .disabled(locked || manager.downloading != nil).accessibilityIdentifier("download-" + kind.rawValue)
                if manager.downloading == nil, manager.messageKind == kind, !manager.message.isEmpty { Text(t(manager.message)).font(.caption).foregroundStyle(.secondary) }
            }
            Text(t("Downloaded once, stored on this Mac. No Python, Ollama or Docker installation is required.")).font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .onAppear { manager.refresh() }
    }
}

private struct CredentialStatus: View {
    @ObservedObject var coordinator: AppCoordinator
    let analysis: Bool
    private var available: Bool { analysis ? coordinator.hasAnalysisKey : coordinator.hasAPIKey }
    private var checking: Bool { analysis ? coordinator.isCheckingAnalysisKey : coordinator.isCheckingKey }
    private var needsAuthorization: Bool { analysis ? coordinator.analysisKeyNeedsAuthorization : coordinator.keyNeedsAuthorization }
    private func t(_ value: String) -> String { L10n.text(value, language: coordinator.settings.language) }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: available ? "checkmark.shield.fill" : "key.horizontal")
                .font(.title2).foregroundStyle(available ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(t(coordinator.isMock ? "Mock credential" : checking ? "Checking Keychain…" : available ? "API key configured" : needsAuthorization ? "API key saved · authorization needed" : "API key not configured")).font(.headline)
                if available && !coordinator.isMock {
                    Text("••••••••").font(.system(.body, design: .monospaced)).accessibilityLabel(t("Key hidden"))
                    Text(t("Credential ready. Its contents are never displayed here.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(t(analysis ? coordinator.analysisKeyStatus : coordinator.keyStatus)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            if checking { ProgressView().controlSize(.small) }
        }.accessibilityElement(children: .contain)
    }
}

struct CredentialEditor: View {
    @ObservedObject var coordinator: AppCoordinator
    let analysis: Bool
    @State private var editing = false
    @State private var value = ""
    @State private var message = ""
    @State private var saving = false
    @State private var confirmingRemoval = false
    private var available: Bool { analysis ? coordinator.hasAnalysisKey : coordinator.hasAPIKey }
    private var checking: Bool { analysis ? coordinator.isCheckingAnalysisKey : coordinator.isCheckingKey }
    private var needsAuthorization: Bool { analysis ? coordinator.analysisKeyNeedsAuthorization : coordinator.keyNeedsAuthorization }
    private func t(_ text: String) -> String { L10n.text(text, language: coordinator.settings.language) }
    var body: some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: 14) {
                CredentialStatus(coordinator: coordinator, analysis: analysis)
                if editing || (!available && !checking && !needsAuthorization) {
                    SecureField(t(available ? "Enter a replacement key" : "Enter a key to save in Keychain"), text: $value)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("credential-input")
                    HStack {
                        Button(t("Save Key")) { save() }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving || coordinator.isMock)
                        if available || needsAuthorization { Button(t("Cancel")) { editing = false; value = "" } }
                    }
                }
                HStack {
                    if (available || needsAuthorization) && !editing { Button(t("Replace key…")) { editing = true; message = "" }.disabled(coordinator.isMock) }
                    Button(t(needsAuthorization ? "Authorize saved key" : "Check saved key")) { analysis ? coordinator.refreshAnalysisKeyState(interactive: true) : coordinator.refreshKeyState(interactive: true) }.disabled(checking || saving)
                    Spacer()
                    if available || needsAuthorization { Button(t("Remove"), role: .destructive) { confirmingRemoval = true }.disabled(saving || checking || coordinator.isMock) }
                }
                if !message.isEmpty { Text(t(message)).font(.caption).textSelection(.enabled) }
                Text(t("Saved securely on this Mac and reused on launch. Existing development keys are imported once; startup never opens an authorization dialog.")).font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        } label: { Text("API Key") }
        .confirmationDialog(t("Remove this service's saved key?"), isPresented: $confirmingRemoval) {
            Button(t("Remove"), role: .destructive) {
                Task {
                    saving = true; defer { saving = false }
                    do { try await coordinator.removeCredential(analysis: analysis); message = "Saved key removed." }
                    catch { message = error.localizedDescription }
                }
            }
            Button(t("Cancel"), role: .cancel) {}
        }
        .onDisappear { value = ""; editing = false }
    }
    private func save() {
        let key = value; value = ""; saving = true
        Task {
            defer { saving = false }
            do { try await coordinator.saveCredential(key, analysis: analysis); editing = false; message = "Saved in macOS Keychain." }
            catch { message = error.localizedDescription }
        }
    }
}

/// Explicit view grouping keeps section labels and controls accessible independently.
struct SettingsSection<Content: View, Heading: View>: View {
    let content: Content
    let heading: Heading
    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Heading) {
        self.content = content(); self.heading = label()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading.font(.headline)
            content.frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }.accessibilityElement(children: .contain)
    }
}

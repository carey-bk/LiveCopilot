import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var hotkeys: HotkeyStore
    @ObservedObject var laya: LayaRuntimeManager
    @ObservedObject var localModels: LocalModelManager
    @ObservedObject var updates: AppUpdateController
    @State private var showDiagnostics = false
    @State private var page = SettingsPage.general
    @State private var serviceRole = 0
    @State private var baseURL = ""
    @State private var apiPath = ""
    @State private var customModel = ""
    @State private var connectionMessage = ""
    @State private var showOpenAIKey = false
    @State private var shortcutConflict = false
    @State private var professionalTermsDraft = ""
    init(coordinator: AppCoordinator, initialPage: SettingsPage = .general, initialServiceRole: Int = 0) { _page = State(initialValue: initialPage); _serviceRole = State(initialValue: initialServiceRole); self.coordinator = coordinator; hotkeys = coordinator.hotkeys; laya = coordinator.laya; updates = coordinator.updates; localModels = coordinator.localModels }
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
            }.frame(width: 180)
                .background { Rectangle().fill(.thinMaterial).ignoresSafeArea(edges: .top) }
            Divider().ignoresSafeArea(edges: .top)
            VStack(alignment: .leading, spacing: 18) {
                UpdateBanner(updates: updates, language: coordinator.settings.language, isBusy: coordinator.isRunning || coordinator.isTransitioning || coordinator.answerIsRunning)
                Text(t(page.rawValue)).font(.system(size: 24, weight: .semibold))
                switch page {
                case .general: ScrollView { general }
                case .services: ScrollView { services }
                case .knowledge: knowledge
                case .history: HistoryView(coordinator: coordinator)
                case .shortcuts: shortcuts
                case .about: ScrollView { about }
                }
            }.padding(page == .history ? 16 : 26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 820, idealWidth: 860, minHeight: 610, idealHeight: 680)
        .background { WindowBackgroundView(style: .white).ignoresSafeArea() }
        .preferredColorScheme(.light)
        .toggleStyle(TrailingSwitchStyle())
        .environment(\.locale, coordinator.settings.language.locale)
        .onAppear { loadCustomDraft() }
        .onChange(of: updates.managementRequest) { _, _ in page = .about }
        .sheet(isPresented: $showDiagnostics) { DiagnosticFeedbackView(settings: coordinator.settings) }
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
                Link(destination: URL(string: coordinator.settings.language.usesTraditionalChinese ? "https://carey-bk.github.io/LiveCopilot/zh-Hant/" : coordinator.settings.language.usesChinese
                                       ? "https://carey-bk.github.io/LiveCopilot/"
                                       : "https://carey-bk.github.io/LiveCopilot/en/")!) {
                    Label(b("Product guide · 中文 / English", "使用介绍 · 中文 / English"), systemImage: "globe")
                }.accessibilityIdentifier("about-guide")
            }.buttonStyle(.link)
            Button { showDiagnostics = true } label: {
                Label(b("Report a problem…", "反馈问题与诊断报告…"), systemImage: "ladybug")
            }.accessibilityIdentifier("diagnostics-open")
            Divider()
            UpdateSettingsView(updates: updates, language: coordinator.settings.language)
        }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(b("Getting started", "新用户引导")).font(.headline)
                    Text(b("Review language, models, services, and permissions. Your existing setup is kept.", "查看语言、模型、服务和权限，保留已有配置。")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button(b("Open guide", "打开引导")) { coordinator.onOpenOnboarding?() }
                        .accessibilityIdentifier("settings-open-onboarding")
                    Button(b("Show floating window tips", "悬浮窗操作提示")) { coordinator.onShowOverlayTips?() }
                        .accessibilityIdentifier("settings-overlay-tips")
                }.fixedSize(horizontal: true, vertical: false)
            }
            SettingsSection {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(t("Interface language"), selection: $coordinator.settings.language) {
                        Text(t("Follow system")).tag(AppLanguage.system)
                        Text("English").tag(AppLanguage.english)
                        Text("简体中文").tag(AppLanguage.simplifiedChinese)
                        Text("繁體中文").tag(AppLanguage.traditionalChinese)
                    }.accessibilityIdentifier("interface-language")
                    Text(t("Changes apply immediately. Set the answer language separately in the floating panel.")).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Picker(t("Floating window background"), selection: $coordinator.settings.background) {
                        ForEach(AppBackground.allCases) { background in
                            Text(t(background.label)).tag(background)
                        }
                    }.pickerStyle(.segmented).accessibilityIdentifier("window-background")
                    Text(t(coordinator.settings.background.detail)).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack(alignment: .top, spacing: 24) {
                        fontSizeControl(b("Transcript text", "流式识别区字号"), value: $coordinator.settings.transcriptFontSize, identifier: "transcript-font-size",
                                        preview: b("What was your role in this project?", "你在这个项目中具体负责什么？"))
                        fontSizeControl(b("Answer text", "回答区字号"), value: $coordinator.settings.answerFontSize, identifier: "answer-font-size",
                                        preview: b("I would start with the goal, then explain the approach.", "我会先说明目标，再介绍具体的方法。"))
                    }
                    Text(b("Text sizes are independent and take effect immediately. The window reflows; longer content scrolls.", "两处字号独立保存、即时生效；窗口会重新排版，较长的内容可滚动阅读。")).font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            } label: { Label(t("Language & appearance"), systemImage: "paintpalette") }
            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(b("Automatically fit answer height", "回答区自动伸缩"), isOn: $coordinator.settings.overlayAutoHeight)
                        .accessibilityIdentifier("overlay-auto-height")
                    Text(b("Fit the window to answer content; longer conversations scroll. The voice and input areas stay fixed. Drag vertically to use a manual height.", "窗口随回答内容伸缩，长会话独立滚动；语音区和输入区保持固定。手动拖动高度后改为手动尺寸。")).font(.caption).foregroundStyle(.secondary)
                    Divider()
            VStack(alignment: .leading, spacing: 12) {
                Toggle(t("Hide the floating window from meeting screen sharing and recording"), isOn: $coordinator.settings.excludeOverlayFromCapture)
                    .accessibilityIdentifier("exclude-overlay-capture")
                Text(t("Keep suggestions visible on your screen while excluding the floating window from capture. Settings and setup remain visible in shared content. Verify the result from another participant before use."))
                    .font(.caption).foregroundStyle(.secondary)
                if coordinator.settings.excludeOverlayFromCapture {
                    switch coordinator.overlayCaptureProtection {
                    case .failed:
                        Label(b("Capture protection is unavailable on this system. The floating window may be recorded.",
                                "当前系统未能启用录制保护，悬浮窗可能被录入。"), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    default: EmptyView()
                    }
                }
            }
                    Divider()
                    Toggle(b("Automatically dock to edge", "自动贴边"), isOn: $coordinator.settings.overlayEdgeHide)
                        .accessibilityIdentifier("overlay-edge-hide")
                    Text(b("When enabled, the window tucks into the right edge and appears on hover. Turn off to drag its header anywhere on your desktop.", "开启后，悬浮窗自动贴靠右侧边缘，悬停时展开。关闭后，可拖动窗口顶部到桌面任意位置。")).font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            } label: { Label(t("Floating window"), systemImage: "rectangle.righthalf.inset.filled") }
            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(t("Show LiveCopilot in the menu bar"), isOn: $coordinator.settings.showMenuBarIcon)
                        .accessibilityIdentifier("show-menu-bar-icon")
                    Text(t("When hidden, use the Dock icon or {shortcut} to open the floating window. You can turn the menu bar icon back on here.")
                        .replacingOccurrences(of: "{shortcut}", with: hotkeys.toggleOverlay.display))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            } label: { Label(t("Menu bar"), systemImage: "menubar.rectangle") }
            SettingsSection {
                VStack(alignment: .leading, spacing: 14) {
                    Picker(t("Operating mode"), selection: $coordinator.settings.mode) {
                        ForEach(OperatingMode.allCases) { Text(t($0.rawValue)).tag($0) }
                    }.disabled(locked)
                    Text(b("Remote Meeting separates system audio (Them) from your microphone (You); In-Person uses one room microphone, without speaker diarization.", "远程会议：系统音频标为对方、麦克风标为我；现场/答辩：仅用房间麦克风，不区分具体说话人。")).font(.caption).foregroundStyle(.secondary)
                    Picker(t("Scenario"), selection: $coordinator.settings.scenario) {
                        ForEach(ScenarioProfile.allCases) { Text(t($0.rawValue)).tag($0) }
                    }.disabled(locked)
                    Text(b("Interview: personal experience and talking points. Meeting: decisions and next actions. Defense: methods, evidence and limitations. These change answer instructions, not ASR accuracy.", "面试：个人经历与表达要点；会议：决策与后续行动；答辩：方法、证据与局限。场景改变回答提示词，不改变语音识别准确率。")).font(.caption).foregroundStyle(.secondary)
                    if locked { Text(t("Stop listening to change mode or scenario.")).font(.caption).foregroundStyle(.secondary) }
                    Toggle(t("Automatic suggestions for meaningful questions"), isOn: $coordinator.settings.automaticSuggestions)
                        .accessibilityIdentifier("automatic-suggestions")
                    Button(b("View real-time answer triggers", "查看实时回答触发")) { page = .services; serviceRole = 1 }
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

        }.padding(.bottom, 4)
    }
    private var automaticTriggerSettings: some View {
        JevSettingsView(coordinator: coordinator, laya: laya)
    }
    private var services: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker(t("Service role"), selection: $serviceRole) {
                Text(b("Speech recognition", "语音识别")).tag(0)
                Text(b("Answer triggers", "实时回答触发")).tag(1)
                Text(b("Knowledge base", "知识库")).tag(2)
                Text(b("Analysis & answers", "分析与回答")).tag(3)
            }.pickerStyle(.segmented).accessibilityIdentifier("service-role")
            switch serviceRole {
            case 1: automaticTriggerSettings
            case 2: embeddingService
            case 3: analysisService
            default: liveService
            }
        }.padding(.bottom, 4)
    }
    private var liveService: some View {
        VStack(alignment: .leading, spacing: 14) {
            liveSection(b("Speech recognition engine", "语音识别引擎")) {
                HStack(spacing: 20) {
                    Picker(b("Engine", "当前引擎"), selection: $coordinator.settings.listeningService) {
                        Text(b("Zipformer · Local Chinese + English · Terminology", "Zipformer · 本地中英双语 · 术语增强")).tag(ListeningService.zipformer)
                        Text(b("Paraformer · Local Chinese + English", "Paraformer · 本地中英双语")).tag(ListeningService.paraformer)
                        Text(b("Apple local speech recognition", "Apple 本机语音识别")).tag(ListeningService.apple)
                        Text("OpenAI · GPT-Live-1").tag(ListeningService.openAI)
                    }.disabled(locked).accessibilityIdentifier("listening-provider")
                    if coordinator.settings.listeningService == .apple {
                        Picker(b("Recognition language", "识别语言"), selection: $coordinator.settings.appleSpeechLanguage) {
                            Text(b("Mandarin Chinese", "普通话")).tag(AppleSpeechLanguage.chinese)
                            Text(b("English (US)", "英语（美国）")).tag(AppleSpeechLanguage.english)
                        }.disabled(locked || coordinator.appleSpeech.busy).accessibilityIdentifier("apple-speech-language")
                    } else {
                        LiveSpeechLanguagePicker(language: $coordinator.settings.liveSpeechLanguage,
                                                 interfaceLanguage: coordinator.settings.language, compact: true).disabled(locked)
                    }
                }
                Text(liveEngineSummary).font(.callout).foregroundStyle(.secondary)
                if coordinator.settings.listeningService == .openAI {
                    Text(ServiceGuide.livePrice(coordinator.settings.liveModel, language: coordinator.settings.language)).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach(liveEngineTags, id: \.self) { label in
                        Text(label).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                }
                if coordinator.settings.listeningService == .apple {
                    Text(b("Only the selected language is recognized. Use Zipformer for mixed Chinese and English.", "仅识别所选语言，不自动切换中英文；混合语言建议使用 Zipformer。"))
                        .font(.caption).foregroundStyle(.secondary)
                } else if coordinator.settings.listeningService == .openAI {
                    Text(b("Language options guide recognition without restricting the languages recognized.", "语言选项仅影响识别偏好，不限制实际识别语言。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(b("Automatically detects complete questions and triggers answer generation.", "自动识别完整提问，触发分析模型生成回答。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if coordinator.settings.listeningService == .zipformer {
                professionalTermsSection
            }
            liveSection(b("Model connection and download management", "模型连接与下载管理")) {
                if coordinator.settings.listeningService == .apple {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(b("Apple speech recognition model", "Apple 语音识别模型")).font(.headline)
                                Text(b("Apple · Single language", "Apple · 单语言")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label(L10n.text(coordinator.appleSpeech.message, language: coordinator.settings.language),
                                  systemImage: coordinator.appleSpeech.installed ? "checkmark.circle.fill" : "arrow.down.circle")
                                .font(.caption).foregroundStyle(coordinator.appleSpeech.installed ? Color.green : Color.secondary)
                        }
                        HStack(spacing: 12) {
                            Button(b("Download / Retry", "下载/重试")) { coordinator.appleSpeech.install(coordinator.settings.appleSpeechLanguage) }
                                .disabled(locked || coordinator.appleSpeech.busy || coordinator.appleSpeech.installed || !coordinator.appleSpeech.available)
                            if coordinator.appleSpeech.busy {
                                ProgressView().controlSize(.small)
                                Button(t("Cancel")) { coordinator.appleSpeech.cancel() }
                            }
                            Spacer()
                            Button(b("Check again", "重新检测")) { Task { await coordinator.appleSpeech.refresh(coordinator.settings.appleSpeechLanguage) } }
                                .disabled(coordinator.appleSpeech.busy)
                        }
                    }
                } else if let kind = coordinator.settings.listeningService.localModel {
                    LocalModelCard(compact: true, manager: coordinator.localModels, kind: kind, language: coordinator.settings.language,
                                   locked: locked || coordinator.isIndexing || coordinator.answerIsRunning,
                                   remove: { coordinator.removeLocalModel(kind) })
                } else {
                    CredentialEditor(coordinator: coordinator, analysis: false, liveLayout: true)
                    DisclosureGroup(b("Advanced model settings", "高级模型设置")) {
                        modelField("Live model", value: $coordinator.settings.liveModel).disabled(locked).padding(.top, 8)
                    }
                }
            }
        }.task(id: coordinator.settings.appleSpeechLanguage) {
            if coordinator.settings.listeningService == .apple { await coordinator.appleSpeech.refresh(coordinator.settings.appleSpeechLanguage) }
        }.task(id: coordinator.settings.listeningService) {
            if coordinator.settings.listeningService == .apple { await coordinator.appleSpeech.refresh(coordinator.settings.appleSpeechLanguage) }
        }
    }
    private var professionalTermsSection: some View {
        liveSection(b("Professional terminology", "专业术语识别")) {
            Toggle(b("Enable terminology enhancement", "启用术语增强"), isOn: Binding(
                get: { coordinator.settings.listeningService == .zipformer && coordinator.settings.professionalTermsEnabled },
                set: { coordinator.settings.professionalTermsEnabled = $0 }))
                .disabled(!ProfessionalTerms.supportsNativeEnhancement(coordinator.settings.listeningService))
            if coordinator.settings.listeningService == .zipformer {
                Text(b("Add technical terms to guide recognition. Edits apply at the next speech segment; results may vary.", "添加专业词汇帮助识别；修改从下一段语音起生效，识别效果因发音而异。"))
                    .font(.caption).foregroundStyle(.secondary)
                if coordinator.localModels.installed.contains(.terminologySpeech), coordinator.settings.professionalTermsEnabled {
                    Text("\(coordinator.activeProfessionalTerms.count) " + b("active terms", "条可用于识别"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(b("Select Zipformer to use terminology enhancement. Your vocabulary is saved locally.", "选择 Zipformer 引擎即可使用术语增强。词表会保存在本机。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if coordinator.settings.professionalTermsEnabled {
                HStack {
                    Text(b("Custom terms", "自定义热词")).font(.callout)
                    Spacer()
                    Text("\(coordinator.settings.professionalTerms.count) " + b("saved terms", "个词条 · 已保存"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextEditor(text: $professionalTermsDraft)
                    .font(.body).frame(height: 120).scrollContentBackground(.hidden)
                    .padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                    .accessibilityLabel(b("One professional term per line", "每行一个专业术语"))
                Text(b("One term per line. Chinese, English, mixed-language terms and phrases with spaces are supported. Blank and duplicate entries are removed when saved.", "每行一个术语，支持中文、英文、中英混合及含空格的词组。保存时自动忽略空行和重复项。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(b("Up to 100 saved entries are considered, each up to 100 characters. Punctuation separates words; unsupported characters are skipped.", "为保持实时性，最多处理前 100 条，每条不超过 100 字。标点按词间空格处理；含模型不支持字符的词条不应用。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(b("Restore examples", "恢复示例")) { professionalTermsDraft = ProfessionalTerms.examples.joined(separator: "\n") }
                    Button(b("Copy terms", "复制热词列表")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(coordinator.settings.professionalTerms.joined(separator: "\n"), forType: .string)
                    }
                }
            }
        }
        .onAppear { professionalTermsDraft = coordinator.settings.professionalTerms.joined(separator: "\n") }
        .onChange(of: professionalTermsDraft) { _, value in coordinator.settings.professionalTerms = ProfessionalTerms.clean(value) }
    }
    private func liveSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private var liveEngineSummary: String {
        switch coordinator.settings.listeningService {
        case .apple: return b("Built-in macOS recognition, transcribing Chinese or English offline.", "使用 macOS 内置识别能力，离线实时转写中文或英文。")
        case .zipformer: return b("Local Chinese/English streaming with native terminology enhancement, no API fees.", "本地中英双语实时识别，支持原生术语增强，无 API 费用。")
        case .paraformer: return b("Transcribes mixed Chinese and English locally, without API fees.", "支持中英文混合语音转写，本地离线运行，无需 API 费用。")
        case .openAI: return b("Cloud transcription with intelligent detection of complete questions.", "云端实时转写，并智能判断提问是否完整。")
        }
    }
    private var liveEngineTags: [String] {
        switch coordinator.settings.listeningService {
        case .apple: return [b("Local", "本地"), b("Single language", "单语识别"), b("No API fees", "无 API 费用")]
        case .zipformer: return [b("Local", "本地"), b("Chinese + English", "中英混合"), b("Terminology", "术语增强"), b("No API fees", "无 API 费用")]
        case .paraformer: return [b("Local", "本地"), b("Chinese + English", "中英混合"), b("No API fees", "无 API 费用")]
        case .openAI: return [b("Cloud", "云端"), b("Multilingual", "多语言"), b("Usage-based", "按量计费")]
        }
    }
    private var embeddingService: some View {
        VStack(alignment: .leading, spacing: 18) {
            liveSection(b("Indexing model", "索引模型")) {
                Picker(t("Embedding provider"), selection: $coordinator.settings.embeddingService) {
                    ForEach(EmbeddingService.allCases) { service in
                        Text(t(service.label) + (service == .local ? b(" · local/free", " · 本地/免费") : b(" · billed per token", " · 按 token 计费"))).tag(service)
                    }
                }.disabled(coordinator.isIndexing || coordinator.answerIsRunning).accessibilityIdentifier("embedding-provider")
                if coordinator.settings.embeddingService == .openAI {
                    modelField("Embedding model", value: $coordinator.settings.embeddingModel).disabled(coordinator.isIndexing)
                    Text(ServiceGuide.embeddingPrice(coordinator.settings.embeddingModel, language: coordinator.settings.language, compact: true))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(b("Runs locally · No API fees", "本地运行 · 无 API 费用")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if coordinator.settings.embeddingService == .local {
                Text(t("Document and query embeddings run on this Mac. No OpenAI key or network is needed after downloading the model.")).font(.callout).foregroundStyle(.secondary)
                LocalModelCard(manager: coordinator.localModels, kind: .embedding, language: coordinator.settings.language, locked: locked || coordinator.isIndexing || coordinator.answerIsRunning, remove: { coordinator.removeLocalModel(.embedding) })
            } else {
                Text(t("Extracted document text and retrieval queries are sent to OpenAI Embeddings using the shared OpenAI credential.")).font(.callout).foregroundStyle(.secondary)
                CredentialEditor(coordinator: coordinator, analysis: false, embeddingLayout: true)
            }
            if coordinator.knowledgeNeedsReindex {
                HStack(spacing: 12) {
                    Label(b("The indexing model has changed. Rebuild existing documents' indexes to use semantic retrieval with this model.", "索引模型已切换，请重新建立已有文档的索引，才能使用当前模型进行语义检索。"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(b("Rebuild indexes", "重新建立索引")) { coordinator.reindexAll() }
                        .disabled(!knowledgeConfigured || coordinator.isIndexing)
                }
            }
            if coordinator.settings.embeddingService == .local { localCost }
            Text(t("After changing the embedding model, re-index documents. Keyword retrieval remains available for older indexes.")).font(.caption).foregroundStyle(.secondary)
            Button(t("Open knowledge library")) { page = .knowledge }
        }
        .task(id: coordinator.settings.selectedEmbeddingIdentity) { await coordinator.verifyEmbeddingIfNeeded() }
        .onChange(of: coordinator.hasAPIKey) { _, available in
            if available { Task { await coordinator.verifyEmbeddingIfNeeded() } }
        }
    }
    private var analysisService: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingAnswerConfiguration(coordinator: coordinator)
            if (try? coordinator.settings.analysisCredentialReference()) != nil {
                CredentialEditor(coordinator: coordinator, analysis: coordinator.settings.reasoningService != .sharedOpenAI, analysisLayout: true)
                    .id(try? coordinator.settings.analysisCredentialReference().account)
            }
            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(b("Chinese / English sentence pairs", "中英逐句对照"), isOn: $coordinator.settings.bilingualAnswers)
                        .accessibilityIdentifier("bilingual-answers")
                    Text(b("Each Chinese sentence is followed by its English equivalent. Applies to manual and automatic answers and overrides single-language output.", "每句中文后紧接对应英文。对手动和自动回答生效，优先于单语设置。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text(b("Additional answer instructions", "个性化额外提示词")).font(.headline)
                    TextEditor(text: Binding(get: { coordinator.settings.additionalAnswerInstructions }, set: { coordinator.settings.additionalAnswerInstructions = String($0.prefix(4000)) }))
                        .font(.body).frame(height: 100).padding(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.25)))
                        .accessibilityLabel(b("Additional answer instructions", "个性化额外提示词"))
                        .accessibilityIdentifier("additional-answer-instructions")
                    HStack {
                        Text(b("Example: Use short sentences and explain technical terms. Sent to your analysis service with each request.", "例如：用短句回答，并解释专业术语。每次请求会随问题发送给分析服务。"))
                        Spacer()
                        Text("\(coordinator.settings.additionalAnswerInstructions.count)/4000").monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            } label: { Text(b("Answer style", "回答风格")) }
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
                CredentialEditor(coordinator: coordinator, analysis: true, analysisLayout: true)
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
        Text(b("Local/free means no API usage fee. The first model download needs a network connection and disk space.", "本地／免费指无 API 调用费。首次模型下载需要联网与磁盘空间。")).font(.caption).foregroundStyle(.secondary)
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
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func modelField(_ title: String, value: Binding<String>, prompt: String? = nil) -> some View {
        HStack {
            Text(t(title)).frame(width: 120, alignment: .leading)
            TextField(t(title), text: value, prompt: Text(prompt ?? t(title))).textFieldStyle(.roundedBorder)
        }
    }
    private var knowledgeConfigured: Bool {
        coordinator.settings.embeddingService == .local
            ? localModels.embeddingVerification.isReady
            : coordinator.hasAPIKey && coordinator.embeddingVerification.isReady
    }
    private var knowledge: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !knowledgeConfigured {
                HStack(spacing: 12) {
                    Label(b("Knowledge indexing is not verified. Configure a local model or API Key and complete verification to continue.", "知识库索引服务尚未验证通过。请前往配置，下载本地模型或保存 API Key 并完成验证。"), systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(b("Configure", "去配置")) { serviceRole = 2; page = .services }
                }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
            knowledgeContent
                .disabled(!knowledgeConfigured)
                .allowsHitTesting(knowledgeConfigured)
                .saturation(knowledgeConfigured ? 1 : 0)
                .opacity(knowledgeConfigured ? 1 : 0.45)
        }.task { if coordinator.settings.embeddingService == .local { await localModels.verifyEmbeddingIfNeeded() } }
    }
    private var knowledgeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Local knowledge base")).font(.headline)
            KnowledgeImportDropZone(language: coordinator.settings.language, isIndexing: coordinator.isIndexing || !knowledgeConfigured,
                                    selectDocuments: selectDocuments, importDocuments: { urls in
                                        guard knowledgeConfigured else { return }; coordinator.importDocuments(urls)
                                    },
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
            if coordinator.indexingDocumentCount > 0 {
                IndexingProgressView(progress: coordinator.indexingProgress,
                                     label: b("Documents completed: ", "已完成文档：") + "\(coordinator.indexingCompletedDocumentCount) / \(coordinator.indexingDocumentCount)")
                    .accessibilityIdentifier("knowledge-index-progress")
            }
            if coordinator.indexingSucceeded {
                Label(b("Index established", "索引已建立"), systemImage: "checkmark.square.fill")
                    .foregroundStyle(.green).accessibilityIdentifier("knowledge-index-complete")
            }
            if !coordinator.knowledgeMessage.isEmpty { Text(t(coordinator.knowledgeMessage)).font(.caption).textSelection(.enabled) }
            if coordinator.settings.embeddingService == .local {
                Button(b("Check local model / copy diagnostics", "检查本地模型 / 复制诊断信息")) { page = .services; serviceRole = 1 }
                    .accessibilityIdentifier("knowledge-model-diagnostics")
            }
            List {
                ForEach(coordinator.knowledgeDocuments) { document in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(document.name).font(.headline)
                        if coordinator.isIndexing && coordinator.indexingDocumentID == document.id {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(b("Building index…", "正在建立索引…")).font(.caption).foregroundStyle(.secondary)
                            }
                        } else if document.status == "Ready" {
                            Label(b("Index established", "索引已建立"), systemImage: "checkmark.square.fill")
                                .font(.caption).foregroundStyle(.green)
                        } else { Text(t(document.status)).font(.caption).foregroundStyle(.secondary) }
                        Text("\(document.chunkCount) \(t("chunks")) · \(document.embeddingModel)").font(.caption).foregroundStyle(.secondary)
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
        guard knowledgeConfigured else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentParser.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.begin { response in if response == .OK && knowledgeConfigured { coordinator.importDocuments(panel.urls) } }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(t("Global shortcuts")).font(.headline)
            HStack {
                Label(t("Show / Hide Overlay"), systemImage: "macwindow").frame(width: 160, alignment: .leading)
                KeyRecorderView(combo: hotkeys.toggleOverlay, language: coordinator.settings.language,
                                onRecordingChanged: coordinator.onHotkeyRecordingChanged) { combo in
                    recordShortcut { coordinator.updateOverlayHotkey(combo) }
                }.frame(width: 140, height: 28).accessibilityIdentifier("shortcut-toggle-overlay")
                Button(t("Reset")) { recordShortcut { coordinator.resetOverlayHotkey() } }
                    .accessibilityIdentifier("reset-shortcut-toggle-overlay")
            }
            Divider()
            ForEach(SuggestionMode.allCases) { mode in
                HStack {
                    Label(t(mode.label), systemImage: mode.systemImage).frame(width: 160, alignment: .leading)
                    KeyRecorderView(combo: hotkeys.combo(for: mode), language: coordinator.settings.language,
                                    onRecordingChanged: coordinator.onHotkeyRecordingChanged) { combo in
                        recordShortcut { coordinator.updateHotkey(combo, for: mode) }
                    }.frame(width: 140, height: 28).accessibilityIdentifier("shortcut-" + mode.rawValue)
                    Button(t("Reset")) { recordShortcut { coordinator.resetHotkey(mode) } }
                }.disabled(!coordinator.settings.isEnabled(mode))
                if !coordinator.settings.isEnabled(mode) {
                    Text(t("Enable this tool in General to use its shortcut.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if shortcutConflict {
                Text(b("This shortcut is already assigned to another action. Choose a different combination.", "这个快捷键已用于其他操作，请选择其他组合。"))
                    .font(.caption).foregroundStyle(.red).accessibilityIdentifier("shortcut-conflict")
            }
            Text(b("Click a shortcut and press a new key combination. Escape cancels; Reset restores its default.", "点击快捷键后按下新的组合键，按 Esc 取消；点击“重置”恢复默认。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(t("{shortcut} shows/hides the overlay. Click the text box to type; Return submits a question even when listening is off.")
                .replacingOccurrences(of: "{shortcut}", with: hotkeys.toggleOverlay.display)).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
    @discardableResult private func recordShortcut(_ update: () -> Bool) -> Bool {
        let accepted = update()
        shortcutConflict = !accepted
        return accepted
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", services = "Services", knowledge = "Knowledge", history = "History", shortcuts = "Shortcuts", about = "About"
    var id: String { rawValue.lowercased() }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .services: return "shippingbox"
        case .knowledge: return "books.vertical"
        case .history: return "clock.arrow.circlepath"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

private struct LocalModelCard: View {
    var compact = false
    @State private var confirmRemoval = false
    @State private var copiedDiagnostics = false
    @ObservedObject var manager: LocalModelManager
    let kind: LocalModelKind
    let language: AppLanguage
    let locked: Bool
    let remove: () -> Void
    private func t(_ text: String) -> String { L10n.text(text, language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(kind == .embedding ? (ServiceGuide.text("Local knowledge index model", "知识库本地索引模型", language)) : kind.title).font(.headline)
                    Text(t("Download size") + " · " + kind.downloadSize).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(statusTitle, systemImage: manager.health[kind]?.ready == true ? "checkmark.circle.fill"
                      : manager.queued.contains(kind) ? "clock" : "arrow.down.circle")
                    .font(.caption).foregroundStyle(manager.health[kind]?.ready == true ? .green : .secondary)
            }
            Text(ServiceGuide.text("Automatically tries available download sources. Progress is for the current file.", "自动尝试可用下载线路；进度显示当前文件的下载比例。", language))
                .font(.caption).foregroundStyle(.secondary)
            if manager.downloading == kind {
                if let value = manager.downloadProgress {
                    ProgressView(value: value)
                    Text("\(Int(value * 100))% · " + manager.transferStatus).font(.caption.monospacedDigit())
                } else { ProgressView().progressViewStyle(.linear); Text(manager.transferStatus).font(.caption) }
                HStack { ProgressView().controlSize(.small); Text(t(manager.message)).font(.caption); Spacer(); Button(t("Cancel")) { manager.cancel() } }
            } else if manager.queued.contains(kind) {
                Text(ServiceGuide.text("Download is queued and will start automatically after the current model.", "已加入下载队列，当前模型完成后会自动开始。", language))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Button(t(manager.installed.contains(kind) ? "Download again" : "Download model")) { copiedDiagnostics = false; manager.install(kind) }
                        .disabled(locked || manager.downloading != nil).accessibilityIdentifier("download-" + kind.rawValue)
                    if manager.installed.contains(kind) {
                        Button(ServiceGuide.text("Run self-check", "运行自检", language)) { copiedDiagnostics = false; manager.runSelfCheck(kind) }
                            .disabled(locked || manager.downloading != nil).accessibilityIdentifier("selfcheck-" + kind.rawValue)
                        Button(ServiceGuide.text("Delete local model…", "删除本地模型…", language), role: .destructive) { confirmRemoval = true }
                            .foregroundStyle(.red)
                            .disabled(locked || manager.downloading != nil)
                            .confirmationDialog(ServiceGuide.text("Delete this local model?", "删除此本地模型？", language), isPresented: $confirmRemoval) {
                                Button(ServiceGuide.text("Delete", "删除", language), role: .destructive, action: remove)
                            } message: { Text(ServiceGuide.text("Download again to use it. Knowledge documents, indexes and settings are retained.", "下次使用需要重新下载。知识库文档、索引和设置均保留。", language)) }
                    }
                }
                if manager.downloading == nil, manager.messageKind == kind, !manager.message.isEmpty { Text(t(manager.message)).font(.caption).foregroundStyle(.secondary) }
            }
            if let report = manager.health[kind] {
                HStack(alignment: .center, spacing: 12) {
                    Button(copiedDiagnostics ? (ServiceGuide.text("Copied", "已复制", language)) : (ServiceGuide.text("Copy diagnostics", "复制诊断信息", language))) {
                        NSPasteboard.general.clearContents()
                        copiedDiagnostics = NSPasteboard.general.setString(report.diagnostic(kind: kind), forType: .string)
                    }.fixedSize().accessibilityIdentifier("copy-diagnostics-" + kind.rawValue)
                    Text(language.interfaceText(report.advice(english: !language.usesChinese)))
                        .font(.caption).foregroundStyle(report.ready ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("selfcheck-result-" + kind.rawValue)
                }
            }
        }.padding(16).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .onAppear { manager.refresh() }
    }
    private var statusTitle: String {
        if manager.checking == kind { return ServiceGuide.text("Checking…", "正在自检…", language) }
        if let report = manager.health[kind] {
            return report.ready ? (ServiceGuide.text("Self-check passed · offline ready", "自检通过 · 可离线使用", language)) : (ServiceGuide.text("Self-check failed", "自检未通过", language))
        }
        if manager.downloading == kind { return ServiceGuide.text("Downloading…", "正在下载…", language) }
        if manager.installed.contains(kind) { return ServiceGuide.text("Downloaded · not checked", "已下载 · 尚未自检", language) }
        if manager.queued.contains(kind) { return ServiceGuide.text("Queued for download", "等待下载", language) }
        if manager.failures[kind] != nil { return ServiceGuide.text("Download failed", "下载失败", language) }
        return t("Not downloaded")
    }
}

private struct CredentialStatus: View {
    @ObservedObject var coordinator: AppCoordinator
    let analysis: Bool
    var embedding = false
    private var available: Bool { analysis ? coordinator.hasAnalysisKey : coordinator.hasAPIKey }
    private var checking: Bool { analysis ? coordinator.isCheckingAnalysisKey : coordinator.isCheckingKey }
    private var needsAuthorization: Bool { analysis ? coordinator.analysisKeyNeedsAuthorization : coordinator.keyNeedsAuthorization }
    private func t(_ value: String) -> String { L10n.text(value, language: coordinator.settings.language) }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: available ? "checkmark.shield.fill" : "key.horizontal")
                .font(.title2).foregroundStyle((embedding ? coordinator.embeddingVerification.isReady : available) ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(t(embedding ? (coordinator.embeddingVerification.isReady ? "Verified · ready" : available ? "API key saved · verification required" : "API key not configured") : coordinator.isMock ? "Mock credential" : checking ? "Checking Keychain…" : available ? "API key configured" : needsAuthorization ? "API key saved · authorization needed" : "API key not configured")).font(.headline)
                if available && !coordinator.isMock {
                    Text("••••••••").font(.system(.body, design: .monospaced)).accessibilityLabel(t("Key hidden"))
                    Text(t(embedding && !coordinator.embeddingVerification.isReady ? "Key saved. Service verification is still required." : "Credential ready. Its contents are never displayed here.")).font(.caption).foregroundStyle(.secondary)
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
    var onboarding = false
    var liveLayout = false
    var embeddingLayout = false
    var analysisLayout = false
    private var hasConnectionTest: Bool { liveLayout || embeddingLayout || analysisLayout }
    @State private var editing = false
    @State private var value = ""
    @State private var message = ""
    @State private var saving = false
    @State private var confirmingRemoval = false
    @State private var showKeyCheck = false
    @State private var editorVisible = false
    @State private var testingConnection = false
    @State private var connectionTestMessage = ""
    @State private var connectionTestSucceeded = false
    @State private var connectionTestTask: Task<Void, Never>?
    @State private var connectionTestID = UUID()
    @State private var testedCredentialRevision: UUID?
    @State private var connectionFailure: OnboardingConnectionFailure?
    private var effectiveFailure: OnboardingConnectionFailure? {
        if embeddingLayout, case .failed(let message) = coordinator.embeddingVerification {
            return .classify(CopilotError.message(message))
        }
        return connectionFailure
    }
    private var connectionVerified: Bool {
        if analysisLayout { return coordinator.isAnalysisConnectionVerified }
        if embeddingLayout { return coordinator.embeddingVerification.isReady }
        return connectionTestSucceeded
    }
    private var connectionBusy: Bool { testingConnection || (embeddingLayout && coordinator.embeddingVerification.isChecking) }
    private var analysisConnectionIdentity: String {
        let s = coordinator.settings
        return [s.reasoningService.rawValue, s.analysisModel, s.reasoningEffort, s.analysisProcessing.rawValue,
                s.deepSeekEffort, s.presetConnection?.thinking.rawValue ?? "",
                (try? s.analysisCredentialReference().account) ?? "invalid"].joined(separator: "|")
    }
    private var available: Bool { analysis ? coordinator.hasAnalysisKey : coordinator.hasAPIKey }
    private var checking: Bool { analysis ? coordinator.isCheckingAnalysisKey : coordinator.isCheckingKey }
    private var needsAuthorization: Bool { analysis ? coordinator.analysisKeyNeedsAuthorization : coordinator.keyNeedsAuthorization }
    private var credentialIdentity: String {
        analysis ? ((try? coordinator.settings.analysisCredentialReference()).map(CredentialVault.account) ?? coordinator.settings.reasoningService.rawValue) : "live"
    }
    private var checkFeedback: CredentialCheckFeedback? {
        analysis ? coordinator.analysisKeyCheckFeedback : coordinator.liveKeyCheckFeedback
    }
    private func t(_ text: String) -> String { L10n.text(text, language: coordinator.settings.language) }
    var body: some View {
        Group {
            if liveLayout { fields }
            else if onboarding { fields }
            else { SettingsSection { fields.padding(12) } label: { Text("API Key") } }
        }
        .confirmationDialog(t("Remove this service's saved key?"), isPresented: $confirmingRemoval) {
            Button(t("Remove"), role: .destructive) {
                Task {
                    resetConnectionTest(); saving = true; showKeyCheck = false; coordinator.clearCredentialCheckFeedback(analysis: analysis); defer { saving = false }
                    do { try await coordinator.removeCredential(analysis: analysis); message = "Saved key removed." }
                    catch { message = error.localizedDescription }
                }
            }
            Button(t("Cancel"), role: .cancel) {}
        }
        .onAppear { editorVisible = true }
        .onDisappear { editorVisible = false; value = ""; editing = false; resetConnectionTest() }
        .onChange(of: coordinator.settings.liveModel) { _, _ in if liveLayout { resetConnectionTest() } }
        .onChange(of: coordinator.settings.embeddingModel) { _, _ in if embeddingLayout { resetConnectionTest() } }
        .onChange(of: available) { _, newValue in if !newValue { resetConnectionTest() } }
        .onChange(of: analysisConnectionIdentity) { _, _ in if analysisLayout { resetConnectionTest() } }
        .onChange(of: coordinator.answerCredentialRevision) { _, revision in if revision != testedCredentialRevision { resetConnectionTest() } }
        .onChange(of: credentialIdentity) { _, _ in resetConnectionTest(); showKeyCheck = false; coordinator.clearCredentialCheckFeedback(analysis: analysis); message = ""; value = ""; editing = false }
    }
    private var fields: some View {
            VStack(alignment: .leading, spacing: onboarding ? 10 : 14) {
                CredentialStatus(coordinator: coordinator, analysis: analysis, embedding: embeddingLayout)
                if editing || (!available && !needsAuthorization) {
                    SecureField(t(available ? "Enter a replacement key" : "Enter a key to save in Keychain"), text: $value)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("credential-input")
                }
                HStack(spacing: 10) {
                    if editing || (!available && !needsAuthorization) {
                        Button(liveLayout || embeddingLayout ? ServiceGuide.text("Save and verify", "保存并验证", coordinator.settings.language) : ServiceGuide.text("Save to Keychain", "保存到钥匙串", coordinator.settings.language)) { save() }
                            .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving || checking || connectionBusy || coordinator.isMock)
                        if available || needsAuthorization { Button(t("Cancel")) { editing = false; value = "" } }
                    } else if available || needsAuthorization {
                        Button(t("Replace key…")) { editing = true; message = "" }
                            .disabled(coordinator.isMock || connectionBusy)
                    }
                    Button(t(needsAuthorization ? "Authorize saved key" : "Check key")) {
                        showKeyCheck = true; message = ""
                        _ = analysis ? coordinator.refreshAnalysisKeyState(interactive: true) : coordinator.refreshKeyState(interactive: true)
                    }.disabled(checking || saving || connectionBusy).accessibilityIdentifier("credential-check-saved")
                    .popover(isPresented: $showKeyCheck, arrowEdge: .top) {
                        CredentialCheckResultView(feedback: checkFeedback ?? .checking, language: coordinator.settings.language) {
                            showKeyCheck = false
                        }
                    }
                    if hasConnectionTest {
                        Button(ServiceGuide.text("Test connection", "测试连接", coordinator.settings.language)) { testConnection() }
                            .disabled(!available || saving || checking || connectionBusy || coordinator.isRunning || coordinator.isTransitioning || (analysisLayout && coordinator.settings.analysisModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (coordinator.isMock && !analysisLayout))
                            .accessibilityIdentifier(onboarding ? "onboarding-test-connection" : "credential-test-connection")
                        if connectionBusy {
                            ProgressView().controlSize(.small)
                            if testingConnection { Button(t("Cancel")) { resetConnectionTest() } }
                        }
                        if !connectionBusy && (connectionVerified || effectiveFailure != nil) {
                            OnboardingConnectionFeedback(language: coordinator.settings.language, testing: false,
                                verified: connectionVerified, saved: available, mock: coordinator.isMock,
                                failure: effectiveFailure, compact: true)
                                .lineLimit(1).layoutPriority(-1)
                                .help(effectiveFailure?.detail(coordinator.settings.language) ?? t(connectionTestMessage))
                        }
                    }
                    Spacer(minLength: 0)
                    if available || needsAuthorization { Button(t("Remove"), role: .destructive) { confirmingRemoval = true }.disabled(saving || checking || connectionBusy || coordinator.isMock) }
                }
                .buttonStyle(.bordered)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                if hasConnectionTest, let failure = effectiveFailure, !connectionBusy {
                    Text(failure.detail(coordinator.settings.language)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier("credential-connection-failure-detail")
                }
                if let checkFeedback, !connectionVerified {
                    Label(checkFeedback.message(coordinator.settings.language), systemImage: checkFeedback.symbol)
                        .font(.caption).foregroundStyle(checkFeedback == .found ? Color.green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("credential-check-result")
                }
                if !message.isEmpty { Text(t(message)).font(.caption).textSelection(.enabled) }
                Text((onboarding || liveLayout)
                     ? ServiceGuide.text("Saved in macOS Keychain on this Mac. Each provider's key is managed separately.", "密钥保存在本机 macOS 钥匙串，各服务商密钥独立管理。", coordinator.settings.language)
                     : t("Saved securely on this Mac and reused on launch."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if analysisLayout {
                    Text(ServiceGuide.text("Testing sends one short example question, without your conversation or documents, and may incur API charges.", "测试仅发送一条简短示例问题，不附带对话或资料，可能产生 API 费用。", coordinator.settings.language))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
    }
    private func resetConnectionTest() {
        connectionTestID = UUID(); connectionTestTask?.cancel(); connectionTestTask = nil
        testingConnection = false; connectionTestMessage = ""; connectionTestSucceeded = false; connectionFailure = nil
    }
    private func testConnection() {
        resetConnectionTest()
        testingConnection = true; connectionTestMessage = embeddingLayout ? "Connecting to the embedding service…" : "Connecting to the speech service…"
        let id = connectionTestID
        testedCredentialRevision = coordinator.answerCredentialRevision
        connectionTestTask = Task { @MainActor in
            do {
                if analysisLayout { try await coordinator.testAnalysisConnection() }
                else if embeddingLayout { try await coordinator.testEmbeddingConnection() }
                else { try await coordinator.testLiveConnection() }
                guard !Task.isCancelled, id == connectionTestID else { return }
                connectionTestSucceeded = true; connectionTestMessage = embeddingLayout ? "Embedding service connection successful." : "Speech service connection successful."
            } catch {
                guard !Task.isCancelled, id == connectionTestID else { return }
                connectionTestSucceeded = false; connectionTestMessage = error.localizedDescription; connectionFailure = .classify(error)
            }
            testingConnection = false
        }
    }
    private func save() {
        resetConnectionTest()
        let key = value; value = ""; saving = true; showKeyCheck = false; coordinator.clearCredentialCheckFeedback(analysis: analysis)
        Task {
            defer { saving = false }
            do { try await coordinator.saveCredential(key, analysis: analysis); editing = false; message = "Saved in macOS Keychain."
                if liveLayout && editorVisible { testConnection() }
            }
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

/// Anchored to the initiating button so results remain visible even in a scrolled card.
struct CredentialCheckResultView: View {
    let feedback: CredentialCheckFeedback
    let language: AppLanguage
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if feedback == .checking { ProgressView().controlSize(.small) }
                else { Image(systemName: feedback.symbol).foregroundStyle(feedback == .found ? Color.green : Color.accentColor) }
                Text(feedback.title(language)).font(.headline)
            }
            Text(feedback.message(language)).font(.system(size: 12))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button(ServiceGuide.text("Done", "知道了", language), action: dismiss) }
        }.padding(18).frame(width: 290, alignment: .leading)
            .accessibilityIdentifier("credential-check-popover")
    }
}

/// Presentation-only presets; persisted thresholds and the inference policy stay unchanged.
enum JevSensitivity: Int, CaseIterable {
    case low, lower, medium, higher, high
    var threshold: Double {
        switch self {
        case .low: return 0.95
        case .lower: return 0.9
        case .medium: return 0.8
        case .higher: return 0.65
        case .high: return 0.5
        }
    }
    static func nearest(to threshold: Double) -> Self {
        guard threshold.isFinite else { return .medium }
        return allCases.min { abs($0.threshold - threshold) < abs($1.threshold - threshold) } ?? .medium
    }
    func title(_ language: AppLanguage) -> String {
        switch self {
        case .low: return ServiceGuide.text("Low", "低", language)
        case .lower: return ServiceGuide.text("Lower", "较低", language)
        case .medium: return ServiceGuide.text("Medium", "中", language)
        case .higher: return ServiceGuide.text("Higher", "较高", language)
        case .high: return ServiceGuide.text("High", "高", language)
        }
    }
}

/// Compact controls for the existing automatic-trigger path. Runtime diagnostics remain in the manager.
private struct JevSettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var laya: LayaRuntimeManager
    @State private var confirmRemoval = false
    @State private var testText = ""
    @State private var result: LayaDiagnosticResult?
    @State private var testError = ""
    @State private var testTask: Task<Void, Never>?
    private var locked: Bool { coordinator.isRunning || coordinator.isTransitioning || coordinator.isTestingLaya }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    private var running: Bool { laya.isReady && coordinator.isRunning && coordinator.settings.automaticSuggestions && coordinator.settings.listeningService.isLocal }
    private var stateTitle: String {
        switch laya.state {
        case .unsupported: return b("Unavailable on this Mac", "此 Mac 不支持")
        case .notInstalled: return b("Not downloaded", "未下载")
        case .installed: return b("Downloaded · Not loaded", "已下载 · 未加载")
        case .installing: return b("Downloading / Installing…", "正在下载与安装…")
        case .loading: return b("Loading and checking…", "正在加载与检测…")
        case .ready: return running ? b("Running", "运行中") : b("Loaded · Standby", "已加载 · 待机")
        case .failed: return b("Load / runtime failed", "加载或运行失败")
        }
    }
    private var stateColor: Color { laya.state == .failed ? .red : (laya.isReady ? .green : .secondary) }
    private var stateIcon: String { laya.state == .failed ? "exclamationmark.circle" : (laya.isReady ? "checkmark.circle.fill" : "cpu") }
    private var sensitivity: JevSensitivity { .nearest(to: coordinator.settings.layaThreshold) }
    private var sensitivityBinding: Binding<Double> {
        Binding(get: { Double(sensitivity.rawValue) }, set: { value in
            guard value.isFinite, let level = JevSensitivity(rawValue: Int(value.rounded())) else { return }
            coordinator.settings.layaThreshold = level.threshold
        })
    }
    private var modelActionTitle: String {
        switch laya.state {
        case .ready: return b("Loaded", "已加载")
        case .loading: return b("Checking…", "检测中…")
        case .installing: return b("Downloading…", "下载中…")
        case .installed: return b("Load model", "加载模型")
        case .failed: return laya.isInstalled ? b("Retry loading", "重试加载") : b("Retry download", "重试下载")
        default: return b("Download model", "下载模型")
        }
    }
    private var continuousQuestionDescription: String {
        switch coordinator.settings.continuousQuestionPolicy {
        case .fast: return b("Respond to each clear request as soon as possible.", "回应意图明确后，尽快分别回答。")
        case .smart: return b("Keep the first answer fast; merge related follow-ups.", "首答保持快速，相关补充问题智能合并。")
        case .complete: return b("Wait briefly for follow-ups before answering.", "短暂等待后续补充，再生成完整回答。")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            card {
                Toggle(isOn: $coordinator.settings.automaticSuggestions) {
                    Text("Jev Mode").font(.headline).accessibilityAddTraits(.isHeader)
                }.disabled(coordinator.isTestingLaya).accessibilityIdentifier("jev-enabled")
                Text(b("Recognize when a response is needed and automatically generate answers.", "判断此时是否需要回应，自动生成回答。"))
                    .font(.callout).foregroundStyle(.secondary)
                Label("Laya · " + stateTitle, systemImage: stateIcon)
                    .font(.caption).foregroundStyle(stateColor).accessibilityIdentifier("laya-runtime-status")
                if coordinator.settings.listeningService == .openAI {
                    Text(b("GPT-Live-1 handles triggering; Laya sensitivity applies to local speech engines.", "当前由 GPT-Live-1 触发；Laya 灵敏度用于本地语音引擎。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 2)
                HStack(spacing: 8) {
                    Text(b("Trigger sensitivity", "触发灵敏度")).font(.subheadline.weight(.medium))
                    Text(sensitivity.title(coordinator.settings.language)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("laya-sensitivity-level")
                    Spacer()
                    Button(b("Restore recommended", "恢复推荐值")) { coordinator.settings.layaThreshold = JevSensitivity.medium.threshold }
                        .disabled(coordinator.isTestingLaya || coordinator.settings.layaThreshold == JevSensitivity.medium.threshold)
                        .accessibilityIdentifier("laya-reset-threshold")
                }
                Slider(value: sensitivityBinding, in: 0...4, step: 1)
                    .disabled(coordinator.isTestingLaya).accessibilityLabel(b("Trigger sensitivity", "触发灵敏度"))
                    .accessibilityValue(sensitivity.title(coordinator.settings.language)).accessibilityIdentifier("laya-threshold")
                HStack {
                    Text(b("Fewer false triggers", "减少误触发"))
                    Spacer()
                    Text(b("More responses", "更多响应"))
                }.font(.caption).foregroundStyle(.secondary)
            }
            card {
                HStack {
                    Text(b("Local model management", "本地模型管理")).font(.headline)
                    Spacer()
                    Label("Laya · " + stateTitle, systemImage: stateIcon).font(.caption).foregroundStyle(stateColor)
                        .accessibilityIdentifier("laya-install-status")
                }
                HStack(spacing: 8) {
                    Button(modelActionTitle) { if laya.isInstalled { laya.prepare() } else { laya.install() } }
                        .disabled(laya.isReady || laya.isBusy || locked || laya.state == .unsupported).accessibilityIdentifier("install-laya")
                    Button(b("Check model", "检测模型")) { laya.checkModel() }
                        .disabled(!laya.isInstalled || laya.isBusy || locked).accessibilityIdentifier("check-laya")
                    if laya.isBusy {
                        Button(b("Cancel", "取消")) { coordinator.cancelLayaRuntime() }.accessibilityIdentifier("cancel-laya")
                    }
                    Spacer()
                    Button(b("Delete…", "删除…"), role: .destructive) { confirmRemoval = true }
                        .foregroundStyle(.red).disabled(laya.isBusy || locked || laya.state == .notInstalled || laya.state == .unsupported)
                        .accessibilityIdentifier("remove-laya")
                        .confirmationDialog(b("Delete Laya model, runtime and download cache?", "删除 Laya 模型、运行环境和下载缓存？"), isPresented: $confirmRemoval) {
                            Button(b("Delete", "删除"), role: .destructive) { if !locked { laya.removeDownloadedFiles() } }
                        } message: { Text(b("You will need to download again. Settings and knowledge documents are retained.", "下次使用需要重新下载；保留设置与知识库资料。")) }
                }
                if laya.isBusy {
                    if let value = laya.transferProgress ?? laya.progress { ProgressView(value: value) }
                    else { ProgressView().progressViewStyle(.linear) }
                    if !laya.transferStatus.isEmpty { Text(laya.transferStatus).font(.caption.monospacedDigit()) }
                }
                if laya.state == .failed {
                    Text(b("Retry the model; manual answers remain available.", "请重试模型；仍可手动生成回答。"))
                        .font(.caption).foregroundStyle(.red)
                }
                if coordinator.isRunning || coordinator.isTransitioning {
                    Text(b("Stop listening to manage the model.", "停止监听后可管理模型。")).font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup(b("Test automatic triggering", "测试自动触发")) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField(b("Enter a sample question", "输入一段模拟提问"), text: $testText, axis: .vertical)
                            .lineLimit(2...4).textFieldStyle(.roundedBorder).disabled(coordinator.isTestingLaya)
                            .accessibilityIdentifier("laya-test-text")
                        HStack {
                            Button(b("Test local detection", "测试本地判断")) {
                                result = nil; testError = ""
                                testTask = Task {
                                    do { result = try await coordinator.testLayaTrigger(text: testText) }
                                    catch is CancellationError { }
                                    catch { testError = b("Test failed. Check the model and retry.", "测试失败，请检测模型后重试。") }
                                }
                            }.disabled(locked || laya.isBusy || !laya.isInstalled || testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testText.utf8.count > 65536)
                                .accessibilityIdentifier("laya-test-run")
                            if coordinator.isTestingLaya { ProgressView().controlSize(.small) }
                            if let result {
                                Label(result.decision.shouldTrigger ? b("Would trigger", "建议触发") : b("Keep waiting", "继续等待"),
                                      systemImage: result.decision.shouldTrigger ? "checkmark.circle.fill" : "clock")
                                    .foregroundStyle(result.decision.shouldTrigger ? Color.green : Color.secondary)
                            }
                        }
                        if let result {
                            Text(b("Local decision", "本地判断") + String(format: " %.1f ms", result.predictionMS))
                                .font(.caption.monospacedDigit()).accessibilityIdentifier("laya-test-result")
                            if result.preparationMS > 5 {
                                Text(b("Model preparation", "模型准备") + String(format: " %.0f ms", result.preparationMS)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(reason(result.decision)).font(.caption).foregroundStyle(.secondary)
                        }
                        if !testError.isEmpty { Text(testError).font(.caption).foregroundStyle(.red) }
                        Text(b("Local test only; no paid API call. Timing excludes audio, transcription, waiting and answer generation.", "仅测试本地判断，不调用付费 API。耗时不含收音、转写、静音等待与回答生成。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }.accessibilityIdentifier("laya-test-section")
            }
            card {
                Text(b("Continuous questions", "连续提问处理")).font(.headline)
                Picker(b("Continuous questions", "连续提问处理"), selection: $coordinator.settings.continuousQuestionPolicy) {
                    ForEach(ContinuousQuestionPolicy.allCases) { policy in Text(L10n.text(policy.label, language: coordinator.settings.language)).tag(policy) }
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("continuous-question-policy")
                Text(continuousQuestionDescription).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("continuous-question-description")
                Label(b("All modes keep previous answers; new answers never overwrite them.", "所有模式均保留历史回答，新回答不会覆盖旧回答。"), systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.controlSize(.regular)
        .onChange(of: testText) { _, _ in result = nil; testError = "" }
        .onChange(of: coordinator.settings.layaThreshold) { _, _ in result = nil }
        .onDisappear { testTask?.cancel() }
    }
    private func reason(_ decision: LayaTriggerDecision) -> String {
        switch decision {
        case .belowThreshold: return b("The score is below the current threshold.", "判断分数低于当前阈值。")
        case .threshold: return b("The score meets the current threshold.", "判断分数达到当前阈值。")
        }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content).padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

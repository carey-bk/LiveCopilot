import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct SettingsView: View {
    enum ServiceRole: Int {
        case speechRecognition = 0
        case answerTriggers = 1
        case knowledgeIndexing = 2
        case analysisAndAnswers = 3
    }
    static let knowledgeModelDiagnosticsTarget: (page: SettingsPage, serviceRole: ServiceRole) = (.services, .knowledgeIndexing)

    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var hotkeys: HotkeyStore
    @ObservedObject var laya: LayaRuntimeManager
    @ObservedObject var localModels: LocalModelManager
    @ObservedObject var updates: AppUpdateController
    @StateObject var permissions: OnboardingPermissions
    @State var showDiagnostics = false
    /// Set 5 s after a successful import; hides the finished progress bar and status line.
    @State var importStatusCollapsed = false
    @State var page = SettingsPage.overview
    @State var serviceRole = 0
    @State var baseURL = ""
    @State var apiPath = ""
    @State var customModel = ""
    @State var connectionMessage = ""
    @State var showOpenAIKey = false
    @State var shortcutConflict = false
    @State var professionalTermsDraft = ""
    @State var answerInstructionsDraft = ""
    init(coordinator: AppCoordinator, initialPage: SettingsPage = .overview, initialServiceRole: Int = 0) { _permissions = StateObject(wrappedValue: OnboardingPermissions(mock: coordinator.isMock)); _page = State(initialValue: initialPage); _serviceRole = State(initialValue: initialServiceRole); self.coordinator = coordinator; hotkeys = coordinator.hotkeys; laya = coordinator.laya; updates = coordinator.updates; localModels = coordinator.localModels }
    func t(_ text: String) -> String { L10n.text(text, language: coordinator.settings.language) }
    func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, coordinator.settings.language) }
    var locked: Bool { coordinator.isRunning || coordinator.isTransitioning }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(LC.hairline).frame(width: 1).ignoresSafeArea(edges: .top)
            VStack(alignment: .leading, spacing: 18) {
                UpdateBanner(updates: updates, language: coordinator.settings.language, isBusy: coordinator.isRunning || coordinator.isTransitioning || coordinator.answerIsRunning)
                LCPageHeader(breadcrumb: ["LiveCopilot", groupTitle(page.group)], title: pageTitle(page), subtitle: pageSubtitle(page))
                switch page {
                case .overview: LCScrollView { overview }
                case .general: LCScrollView { general }
                case .modesAndScenarios: LCScrollView { modesAndScenarios }
                case .services: LCScrollView { services }
                case .knowledge: knowledge
                case .history: HistoryView(coordinator: coordinator).lcCard(padding: 0).clipShape(RoundedRectangle(cornerRadius: LC.Radius.card, style: .continuous))
                case .shortcuts: LCScrollView { shortcuts }
                case .about: LCScrollView { about }
                }
            }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, page == .history ? 20 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 860, idealWidth: 920, minHeight: 620, idealHeight: 700)
        .background { LC.canvas.ignoresSafeArea() }
        .toggleStyle(TrailingSwitchStyle())
        .environment(\.locale, coordinator.settings.language.locale)
        .onAppear { loadCustomDraft(); answerInstructionsDraft = coordinator.settings.additionalAnswerInstructions }
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppBrandTitle(iconSize: 26, titleSize: 18)
                .padding(.horizontal, 18).padding(.top, 40)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(SettingsPage.Group.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        LCSidebarGroupLabel(title: groupTitle(group))
                        ForEach(SettingsPage.allCases.filter { $0.group == group }) { item in
                            Button { page = item } label: {
                                LCSidebarItem(title: pageTitle(item), systemImage: item.icon, selected: page == item,
                                              badge: item == .knowledge && !coordinator.knowledgeDocuments.isEmpty ? "\(coordinator.knowledgeDocuments.count)" : nil)
                            }.buttonStyle(.plain).accessibilityIdentifier("settings-" + item.id)
                        }
                    }
                }
            }.padding(.horizontal, 10)
            Spacer()
            HStack(spacing: 8) {
                LCStatusDot(tone: coordinator.isRunning ? .success : .neutral, pulsing: coordinator.isRunning)
                Text(coordinator.isRunning ? b("Listening", "正在监听") : (coordinator.isMock ? t("MOCK — no API calls") : AppInfo.display))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.padding(18)
        }.frame(width: 208)
    }

    func pageTitle(_ page: SettingsPage) -> String { page == .overview ? b("Overview", "概览") : t(page.rawValue) }
    func groupTitle(_ group: SettingsPage.Group) -> String {
        switch group {
        case .live: return b("Live", "实时")
        case .library: return b("Library", "资料")
        case .app: return b("App", "应用")
        }
    }
    func pageSubtitle(_ page: SettingsPage) -> String {
        switch page {
        case .overview: return b("What is ready for your next conversation, at a glance.", "一眼查看下一场对话前的准备情况。")
        case .general: return b("Language, appearance and floating window behaviour.", "语言、外观与悬浮窗行为。")
        case .modesAndScenarios: return b("How LiveCopilot listens and what kind of answers it prepares.", "如何监听对话，以及准备哪类回答。")
        case .services: return b("Speech recognition, answer triggers, knowledge indexing and answer models.", "语音识别、回答触发、知识库索引与回答模型。")
        case .knowledge: return b("Local documents that ground answers in your own evidence.", "用你自己的资料作为回答依据，原件保留在本机。")
        case .history: return b("Past sessions, questions and answers, stored on this Mac.", "过往会话、问题与回答，保存在本机。")
        case .shortcuts: return b("Global shortcuts that work while another app is in front.", "在其他应用前台时也能使用的全局快捷键。")
        case .about: return b("Version, updates, help and feedback.", "版本、更新、帮助与反馈。")
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case overview = "Overview", modesAndScenarios = "Modes & Scenarios", services = "Services", knowledge = "Knowledge", history = "History", general = "General", shortcuts = "Shortcuts", about = "About"
    enum Group: CaseIterable { case live, library, app }
    var id: String { rawValue.lowercased() }
    var group: Group {
        switch self {
        case .overview, .modesAndScenarios, .services: return .live
        case .knowledge, .history: return .library
        case .general, .shortcuts, .about: return .app
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .general: return "slider.horizontal.3"
        case .modesAndScenarios: return "waveform"
        case .services: return "shippingbox"
        case .knowledge: return "books.vertical"
        case .history: return "clock.arrow.circlepath"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

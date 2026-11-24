import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

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
struct JevSettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var laya: LayaRuntimeManager
    /// Jev Mode is switched in Modes & Scenarios; this tab only shows its state.
    var showModes: (() -> Void)?
    @State private var confirmLegacyCleanup = false
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
        case .installed: return laya.wasVerified ? b("Ready · Loads when listening", "已就绪 · 监听时加载") : b("Downloaded · Not verified", "已下载 · 待验证")
        case .installing: return b("Downloading / Installing…", "正在下载与安装…")
        case .loading: return b("Loading and checking…", "正在加载与检测…")
        case .ready: return running ? b("Running", "运行中") : b("Loaded · Standby", "已加载 · 待机")
        case .failed: return b("Load / runtime failed", "加载或运行失败")
        }
    }
    private var stateColor: Color { laya.state == .failed ? LC.danger : (laya.displayState == .ready ? LC.success : Color.secondary) }
    private var stateIcon: String { laya.state == .failed ? "exclamationmark.circle" : (laya.displayState == .ready ? "checkmark.circle.fill" : "cpu") }
    private var sensitivity: JevSensitivity { .nearest(to: coordinator.settings.layaThreshold) }
    private var sensitivityLevels: [JevSensitivity] {
        return [.low, .medium, .high]
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
    /// What each level does, from the thresholds in JevSensitivity.
    private var sensitivityDescription: String {
        switch sensitivity {
        case .low, .lower: return b("Answers only clear, complete questions. Fewest false triggers.", "只在问题清楚完整时回答，误触发最少。")
        case .medium: return b("Balances answering promptly with avoiding false triggers.", "兼顾及时回答与避免误触发。")
        case .higher, .high: return b("Responds more readily, including looser questions; may trigger more often.", "更积极地回应，较模糊的提问也会回答，可能多一些误触发。")
        }
    }
    /// A segmented control when the labels fit, otherwise a menu, so long English labels never truncate.
    private func choice<Value: Hashable>(_ title: String, selection: Binding<Value>, options: [(Value, String)]) -> some View {
        ViewThatFits(in: .horizontal) {
            Picker(title, selection: selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker(title, selection: selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }.pickerStyle(.menu).labelsHidden().fixedSize()
        }
    }
    /// Short enough for a segmented control in a half-width card; the description below gives the detail.
    private func shortLabel(_ policy: ContinuousQuestionPolicy) -> String {
        switch policy {
        case .fast: return b("Fast", "快速响应")
        case .smart: return b("Merge", "智能合并")
        case .complete: return b("Wait", "完整优先")
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
        VStack(alignment: .leading, spacing: 16) {
            switchStatus
            // Two short choices side by side; each card says what the selected option does.
            HStack(alignment: .top, spacing: 14) {
                LCSettingsCard(b("Trigger sensitivity", "触发灵敏度"), systemImage: "dial.medium") {
                    choice(b("Trigger sensitivity", "触发灵敏度"), selection: Binding(get: { sensitivity }, set: { coordinator.settings.layaThreshold = $0.threshold }),
                           options: sensitivityLevels.map { ($0, $0.title(coordinator.settings.language) + ($0 == .medium ? b(" (rec.)", "（推荐）") : "")) })
                        .disabled(coordinator.isTestingLaya)
                        .accessibilityIdentifier("laya-threshold")
                    Text(sensitivityDescription).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("laya-sensitivity-level")
                    if coordinator.settings.listeningService == .openAI {
                        Text(b("GPT-Live-1 handles triggering now; this applies to local speech engines.", "当前由 GPT-Live-1 触发；此设置用于本地语音引擎。"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                LCSettingsCard(b("Continuous questions", "连续提问处理"), systemImage: "text.bubble") {
                    choice(b("Continuous questions", "连续提问处理"), selection: $coordinator.settings.continuousQuestionPolicy,
                           options: ContinuousQuestionPolicy.allCases.map { ($0, shortLabel($0)) })
                        .accessibilityIdentifier("continuous-question-policy")
                    Text(continuousQuestionDescription).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("continuous-question-description")
                    Label(b("Previous answers are always kept.", "历史回答始终保留，不会被覆盖。"), systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
            LCSettingsCard(b("Local trigger model", "本地触发模型"), subtitle: laya.engineTitle, systemImage: "cpu") {
                HStack(spacing: 8) {
                    Button(modelActionTitle) { if laya.isInstalled { laya.prepare() } else { laya.install() } }
                        .disabled(laya.isReady || laya.isBusy || locked || laya.state == .unsupported).accessibilityIdentifier("install-laya")
                    Button(b("Check model", "检测模型")) { laya.checkModel() }
                        .disabled(!laya.isInstalled || laya.isBusy || locked).accessibilityIdentifier("check-laya")
                    if laya.isBusy {
                        Button(b("Cancel", "取消")) { coordinator.cancelLayaRuntime() }.accessibilityIdentifier("cancel-laya")
                    }
                    Spacer()
                }
                if laya.isBusy {
                    if let value = laya.transferProgress ?? laya.progress { ProgressView(value: value) }
                    else { ProgressView().progressViewStyle(.linear) }
                    if !laya.transferStatus.isEmpty { Text(laya.transferStatus).font(.caption.monospacedDigit()) }
                }
                if laya.state == .failed {
                    Text(b("Retry the model; manual answers remain available.", "请重试模型；仍可手动生成回答。"))
                        .font(.caption).foregroundStyle(LC.danger)
                }
                if coordinator.isRunning || coordinator.isTransitioning {
                    Text(b("Stop listening to manage the model.", "停止监听后可管理模型。")).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
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
                                    .foregroundStyle(result.decision.shouldTrigger ? LC.success : Color.secondary)
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
                        if !testError.isEmpty { Text(testError).font(.caption).foregroundStyle(LC.danger) }
                        Text(b("Local test only; no paid API call. Timing excludes audio, transcription, waiting and answer generation.", "仅测试本地判断，不调用付费 API。耗时不含收音、转写、静音等待与回答生成。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }.accessibilityIdentifier("laya-test-section")
            } accessory: {
                Label(stateTitle, systemImage: stateIcon).font(.caption.weight(.medium)).foregroundStyle(stateColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(stateColor.opacity(0.12), in: Capsule())
                    .fixedSize()
                    .accessibilityIdentifier("laya-install-status")
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
    private var switchStatus: some View {
        let on = coordinator.settings.automaticSuggestions
        return HStack(spacing: 10) {
            LCStatusDot(tone: on ? .success : .neutral)
            Text("Jev Mode").font(.custom(AppBrandTitle.fontName, size: 15))
            Text(on ? b("On", "已开启") : b("Off · answers only when you ask", "已关闭 · 只在你提问时回答"))
                .font(.callout.weight(.medium)).foregroundStyle(on ? Color.primary : Color.secondary)
            Label(laya.engineTitle + " · " + stateTitle, systemImage: stateIcon)
                .font(.caption).foregroundStyle(stateColor).lineLimit(1)
                .accessibilityIdentifier("laya-runtime-status")
            Spacer(minLength: 8)
            if let showModes {
                Button(action: showModes) {
                    HStack(spacing: 4) { Text(b("Switch in Modes & Scenarios", "在模式与场景中切换")); Image(systemName: "arrow.right").font(.caption.weight(.semibold)) }
                        .font(.callout).foregroundStyle(LC.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("jev-switch-location")
            }
        }
        .lcCallout(on ? .accent : .neutral, padding: 12)
    }
}

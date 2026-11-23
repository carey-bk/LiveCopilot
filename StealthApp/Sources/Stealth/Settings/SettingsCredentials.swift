import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct LocalModelCard: View {
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
                    Text(kind == .embedding ? (ServiceGuide.text("\(LocalModelKind.embeddingName) local index model", "\(LocalModelKind.embeddingName) 本地索引模型", language)) : kind.title).font(.headline)
                    Text(t("Download size") + " · " + kind.downloadSize).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(statusTitle, systemImage: manager.health[kind]?.ready == true ? "checkmark.circle.fill"
                      : manager.queued.contains(kind) ? "clock" : "arrow.down.circle")
                    .font(.caption).foregroundStyle(manager.health[kind]?.ready == true ? LC.success : Color.secondary)
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
                    if !kind.isBundled {
                    Button(t(manager.installed.contains(kind) ? "Download again" : "Download model")) { copiedDiagnostics = false; manager.install(kind) }
                        .disabled(locked || manager.downloading != nil).accessibilityIdentifier("download-" + kind.rawValue)
                    }
                    if manager.installed.contains(kind) {
                        Button(ServiceGuide.text("Run self-check", "运行自检", language)) { copiedDiagnostics = false; manager.runSelfCheck(kind) }
                            .disabled(locked || manager.downloading != nil).accessibilityIdentifier("selfcheck-" + kind.rawValue)
                        if !kind.isBundled {
                        Button(ServiceGuide.text("Delete local model…", "删除本地模型…", language), role: .destructive) { confirmRemoval = true }
                            .foregroundStyle(LC.danger)
                            .disabled(locked || manager.downloading != nil)
                            .confirmationDialog(ServiceGuide.text("Delete this local model?", "删除此本地模型？", language), isPresented: $confirmRemoval) {
                                Button(ServiceGuide.text("Delete", "删除", language), role: .destructive, action: remove)
                            } message: { Text(ServiceGuide.text("Download again to use it. Knowledge documents, indexes and settings are retained.", "下次使用需要重新下载。知识库文档、索引和设置均保留。", language)) }
                        }
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
                        .font(.caption).foregroundStyle(report.ready ? Color.secondary : LC.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("selfcheck-result-" + kind.rawValue)
                }
            }
        }.lcCard()
            .onAppear { manager.refresh() }
    }
    private var statusTitle: String {
        if manager.checking == kind { return ServiceGuide.text("Checking…", "正在自检…", language) }
        if let report = manager.health[kind] {
            if kind == .embedding && report.ready { return ServiceGuide.text("Self-check passed · offline indexing ready", "自检通过，可离线用于知识库索引", language) }
            return report.ready ? (ServiceGuide.text("Self-check passed · offline ready", "自检通过 · 可离线使用", language)) : (ServiceGuide.text("Self-check failed", "自检未通过", language))
        }
        if manager.downloading == kind { return ServiceGuide.text("Downloading…", "正在下载…", language) }
        if manager.installed.contains(kind) { return ServiceGuide.text("Downloaded · not checked", "已下载 · 尚未自检", language) }
        if manager.queued.contains(kind) { return ServiceGuide.text("Queued for download", "等待下载", language) }
        if manager.failures[kind] != nil { return ServiceGuide.text("Download failed", "下载失败", language) }
        return t("Not downloaded")
    }
}

struct CredentialStatus: View {
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
                .font(.title2).foregroundStyle((embedding ? coordinator.embeddingVerification.isReady : available) ? LC.success : .secondary)
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

extension Notification.Name {
    static let onboardingFocusCredential = Notification.Name("livecopilot.onboarding.focusCredential")
}

struct CredentialEditor: View {
    @FocusState private var credentialFocused: Bool

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
        if analysisLayout { return coordinator.analysisConnectionFailure }
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
    private var connectionBusy: Bool { testingConnection || (analysisLayout && coordinator.testingAnalysisConnection) || (embeddingLayout && coordinator.embeddingVerification.isChecking) }
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
        .onReceive(NotificationCenter.default.publisher(for: .onboardingFocusCredential)) { _ in
            guard onboarding else { return }
            editing = true
            credentialFocused = true
        }
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
                        .textFieldStyle(.roundedBorder).focused($credentialFocused).accessibilityIdentifier("credential-input")
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
                        Button(ServiceGuide.text(effectiveFailure == nil ? "Test connection" : "Retry test", effectiveFailure == nil ? "测试连接" : "重新测试", coordinator.settings.language)) { testConnection() }
                            .buttonStyle(.borderedProminent).tint(LC.accent)
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
                        .font(.caption).foregroundStyle(checkFeedback == .found ? LC.success : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("credential-check-result")
                }
                if !message.isEmpty { Text(t(message)).font(.caption).textSelection(.enabled) }
                Text(onboarding ? ServiceGuide.text("Check key confirms the saved key is accessible in this Mac’s Keychain.", "检查密钥会确认本机钥匙串中的密钥能否读取。", coordinator.settings.language) : liveLayout
                     ? ServiceGuide.text("Saved in macOS Keychain on this Mac. Each provider's key is managed separately.", "密钥保存在本机 macOS 钥匙串，各服务商密钥独立管理。", coordinator.settings.language)
                     : t("Saved securely on this Mac and reused on launch."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if onboarding && analysisLayout && connectionVerified && !coordinator.isMock {
                    Label(ServiceGuide.text("Answer service ready. You can continue.", "回答服务已就绪，可以继续。", coordinator.settings.language), systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(LC.success)
                }
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
                .background(LC.surface, in: RoundedRectangle(cornerRadius: LC.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LC.Radius.card, style: .continuous).strokeBorder(LC.hairline))
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
                else { Image(systemName: feedback.symbol).foregroundStyle(feedback == .found ? LC.success : LC.accent) }
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

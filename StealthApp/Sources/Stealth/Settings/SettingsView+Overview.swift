import SwiftUI
import AVFoundation

/// Readiness at a glance. Every value comes from live app state; nothing is estimated.
extension SettingsView {
    var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            sessionCard
            // How the next session listens and answers, with what that means in practice.
            HStack(alignment: .top, spacing: 14) {
                conversationTile(title: b("Mode", "模式"), value: t(coordinator.settings.mode.rawValue),
                                 hint: modeHint, systemImage: coordinator.settings.mode == .remote ? "person.2" : "person.3",
                                 identifier: "overview-mode")
                conversationTile(title: b("Scenario", "场景"), value: t(coordinator.settings.scenario.rawValue),
                                 hint: scenarioHint, systemImage: "theatermasks", identifier: "overview-scenario")
            }
            .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                speechTile.lcHoverable(radius: LC.Radius.card, lift: true)
                answerTile.lcHoverable(radius: LC.Radius.card, lift: true)
                knowledgeTile.lcHoverable(radius: LC.Radius.card, lift: true)
                permissionsTile.lcHoverable(radius: LC.Radius.card, lift: true)
            }
            recentSessions
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { permissions.refresh() }
    }

    private var sessionCard: some View {
        HStack(alignment: .center, spacing: 14) {
            LCIconTile(systemImage: coordinator.isRunning ? "waveform" : "waveform.slash", tone: coordinator.isRunning ? .success : .neutral, size: 36, filled: coordinator.isRunning)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    LCStatusDot(tone: coordinator.isRunning ? .success : .neutral, pulsing: coordinator.isRunning)
                    Text(coordinator.isRunning ? b("Listening", "正在监听") : b("Not listening", "未在监听")).font(.headline)
                }
                autoPill
            }
            Spacer(minLength: 8)
            Text(hotkeys.toggleOverlay.display).font(.caption.monospaced()).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3).lcWell(radius: LC.Radius.small)
                .help(t("Show / Hide Overlay"))
            Button { Task { await coordinator.toggle() } } label: {
                if coordinator.isTransitioning {
                    HStack(spacing: 6) {
                        LCSpinner(size: 11, color: .white)
                        Text(coordinator.isRunning ? b("Stopping…", "正在停止…") : b("Starting…", "正在启动…"))
                    }
                } else {
                    Label(coordinator.isRunning ? t("Stop Listening") : t("Start Listening"),
                          systemImage: coordinator.isRunning ? "stop.fill" : "play.fill")
                }
            }
            .buttonStyle(.borderedProminent).tint(coordinator.isRunning ? LC.danger : LC.accent)
            .disabled(coordinator.isTransitioning)
            .accessibilityIdentifier("overview-toggle-listening")
        }
        .lcCard()
    }

    /// Describes what the code does for each mode: which input is which speaker and who can trigger answers.
    private var modeHint: String {
        switch coordinator.settings.mode {
        case .remote:
            return b("System audio is Them, your microphone is You. Only questions from Them trigger automatic answers.",
                     "系统音频为对方，麦克风为我。只有对方的提问会触发自动回答。")
        case .inPerson:
            return b("One room microphone, speakers are not separated. A question from anyone in the room can trigger an automatic answer.",
                     "只用房间麦克风，不区分说话人。房间里任何人的提问都可能触发自动回答。")
        }
    }
    /// Mirrors ScenarioProfile.instructions, which only change how answers are written.
    private var scenarioHint: String {
        switch coordinator.settings.scenario {
        case .interview:
            return b("Short, natural answers to say aloud. Your documents are used only when a question asks about your experience.",
                     "回答简短自然、便于说出口；只在问到你的经历时引用资料，不编造经历。")
        case .meeting:
            return b("Answers lead with decisions, exact facts, trade-offs and next actions.",
                     "回答突出决策、准确事实、取舍和下一步行动，简短务实。")
        case .defense:
            return b("Answers explain methods and assumptions precisely, with sample sizes and limitations when supported.",
                     "回答准确说明方法与假设，有依据时补充样本量和局限。")
        }
    }
    private func conversationTile(title: String, value: String, hint: String, systemImage: String, identifier: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            LCIconTile(systemImage: systemImage, tone: .accent, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.headline)
                }
                Text(hint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                overviewLink(locked ? b("Stop listening to change", "停止监听后可更改") : b("Change", "更改")) { page = .modesAndScenarios }
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lcCard()
        .lcHoverable(radius: LC.Radius.card, lift: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
    private var autoPill: some View {
        LCPill(text: coordinator.settings.automaticSuggestions ? b("Auto answers on", "自动建议已开") : b("Auto answers off", "自动建议已关"),
               tone: coordinator.settings.automaticSuggestions ? .accent : .neutral).fixedSize()
    }
    private var speechReady: Bool {
        switch coordinator.settings.listeningService {
        case .openAI: return coordinator.hasAPIKey
        case .apple: return coordinator.appleSpeech.installed
        case .zipformer, .paraformer:
            return coordinator.settings.listeningService.localModel?.isInstalled(in: localModels.root) == true
        }
    }
    private var answerReady: Bool {
        coordinator.settings.reasoningService == .sharedOpenAI ? coordinator.hasAPIKey : coordinator.hasAnalysisKey
    }
    private var microphoneReady: Bool { permissions.microphone == .authorized }
    private var readyBadge: (Bool) -> (text: String, tone: LC.Tone) {
        { ready in ready ? (b("Ready", "就绪"), .success) : (b("Needs setup", "待配置"), .warning) }
    }

    private var speechTile: some View {
        LCStatTile(title: b("Speech recognition", "语音识别"),
                   value: t(coordinator.settings.listeningService.label),
                   detail: coordinator.settings.listeningService.isLocal ? b("Runs on this Mac · no API fees", "在本机运行 · 无 API 费用") : b("Cloud · usage-based", "云端 · 按量计费"),
                   systemImage: "waveform", tone: .accent, badge: readyBadge(speechReady)) {
            overviewLink(b("Configure", "去设置")) { serviceRole = ServiceRole.speechRecognition.rawValue; page = .services }
        }
    }

    private var answerTile: some View {
        let model = coordinator.settings.analysisModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return LCStatTile(title: b("Answer model", "回答模型"),
                          value: model.isEmpty ? t(coordinator.settings.reasoningService.label) : model,
                          detail: t(coordinator.settings.reasoningService.label),
                          systemImage: "sparkles", tone: .pink, badge: readyBadge(answerReady)) {
            overviewLink(b("Configure", "去设置")) { serviceRole = ServiceRole.analysisAndAnswers.rawValue; page = .services }
        }
    }

    private var knowledgeTile: some View {
        let documents = coordinator.knowledgeDocuments
        let chunks = documents.reduce(0) { $0 + $1.chunkCount }
        return LCStatTile(title: b("Knowledge base", "知识库"),
                          value: b("\(documents.count) documents", "\(documents.count) 份资料"),
                          detail: documents.isEmpty ? b("Import documents to ground answers.", "导入资料，让回答有据可依。")
                                                    : b("\(chunks) evidence chunks · \(t(coordinator.settings.knowledgeMode.label))", "\(chunks) 个证据片段 · \(t(coordinator.settings.knowledgeMode.label))"),
                          systemImage: "books.vertical", tone: .success,
                          badge: documents.isEmpty ? (b("Empty", "空"), .neutral) : readyBadge(knowledgeConfigured)) {
            overviewLink(b("Open knowledge", "管理资料")) { page = .knowledge }
        }
    }

    private var permissionsTile: some View {
        let granted = (microphoneReady ? 1 : 0) + (permissions.screenAudio ? 1 : 0)
        return LCStatTile(title: b("Permissions", "权限"),
                          value: b("\(granted) of 2 granted", "已授权 \(granted) / 2"),
                          detail: b("Microphone ", "麦克风 ") + (microphoneReady ? "✓" : "—") + b(" · System audio ", " · 系统音频 ") + (permissions.screenAudio ? "✓" : "—"),
                          systemImage: "lock.shield", tone: .warning, badge: readyBadge(granted == 2)) {
            overviewLink(b("Review", "查看")) { page = .general }
        }
    }

    private func overviewLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) { Text(title); Image(systemName: "arrow.right").font(.caption.weight(.semibold)) }
                .font(.callout.weight(.medium)).foregroundStyle(LC.accent)
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var recentSessions: some View {
        let recent = Array(coordinator.sessions.sessions.prefix(4))
        VStack(alignment: .leading, spacing: 10) {
            LCSectionHeader(title: b("Recent sessions", "最近会话"), systemImage: "clock.arrow.circlepath") {
                if !recent.isEmpty { overviewLink(b("All history", "全部记录")) { page = .history } }
            }
            if coordinator.sessions.sessions.count >= 2 {
                // Real durations of the latest sessions, oldest first.
                let trend = Array(coordinator.sessions.sessions.prefix(14).reversed())
                let minutes = Int((trend.reduce(0) { $0 + $1.duration } / 60).rounded())
                HStack(alignment: .bottom, spacing: 12) {
                    LCSparkBars(values: trend.map(\.duration))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(minutes)").font(LC.Typo.headline.monospacedDigit()) + Text(b(" min", " 分钟")).font(LC.Typo.caption).foregroundColor(.secondary)
                        Text(b("across the last \(trend.count) sessions", "最近 \(trend.count) 场会话")).font(LC.Typo.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.bottom, 2)
            }
            if recent.isEmpty {
                Text(b("Sessions appear here after you listen or ask a question.", "开始监听或提问后，会话会出现在这里。"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider() }
                        HStack(spacing: 12) {
                            Text(session.startedAt.formatted(.dateTime.locale(coordinator.settings.language.locale).month().day().hour().minute()))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 96, alignment: .leading)
                            Text(session.title).font(.callout).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(session.durationLabel) · \(session.messageCount) " + b("messages", "条消息"))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }.padding(.vertical, 9)
                    }
                }
            }
        }
        .lcCard()
    }
}

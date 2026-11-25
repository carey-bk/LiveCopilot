import SwiftUI
import AVFoundation

/// Readiness at a glance. Every value comes from live app state; nothing is estimated.
extension SettingsView {
    var overview: some View {
        let readiness = readiness
        let columns = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3)
        return VStack(alignment: .leading, spacing: 16) {
            sessionCard(readiness)
            LazyVGrid(columns: columns, spacing: 14) {
                conversationTile.lcHoverable(radius: LC.Radius.card, lift: true)
                speechTile(readiness[.speech]).lcHoverable(radius: LC.Radius.card, lift: true)
                jevTile(readiness[.triggers])
                answerTile(readiness[.answers]).lcHoverable(radius: LC.Radius.card, lift: true)
                knowledgeTile(readiness[.knowledge]).lcHoverable(radius: LC.Radius.card, lift: true)
                permissionsTile(readiness[.permissions]).lcHoverable(radius: LC.Radius.card, lift: true)
            }
            recentSessions
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { permissions.refresh() }
    }

    /// Setup guide and floating-window tips, small, in the Overview header's free corner.
    var guideButtons: some View {
        HStack(spacing: 8) {
            Button { coordinator.onOpenOnboarding?() } label: { Label(b("Setup guide", "新手引导"), systemImage: "sparkles") }
                .accessibilityIdentifier("settings-open-onboarding")
            Button { coordinator.onShowOverlayTips?() } label: { Label(b("Window tips", "悬浮窗提示"), systemImage: "lightbulb") }
                .accessibilityIdentifier("settings-overlay-tips")
        }
        .controlSize(.small)
        .lcGlassButton()
        .fixedSize()
        .padding(.top, 18)
    }

    private func sessionCard(_ readiness: SettingsReadiness) -> some View {
        HStack(alignment: .center, spacing: 14) {
            LCIconTile(systemImage: coordinator.isRunning ? "waveform" : "pause.fill", tone: coordinator.isRunning ? .success : .neutral, size: 40, filled: coordinator.isRunning)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    LCStatusDot(tone: coordinator.isRunning ? .success : .neutral, pulsing: coordinator.isRunning)
                    Text(coordinator.isRunning ? b("Listening", "正在监听") : b("Not listening", "未在监听")).font(LC.Typo.headline)
                    autoPill
                }
                readinessLine(readiness)
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Text(b("Show / hide", "显示/隐藏")).font(.caption).foregroundStyle(.secondary)
                Text(hotkeys.toggleOverlay.display).font(.caption.monospaced()).foregroundStyle(.primary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4).lcWell(radius: LC.Radius.small)
            .fixedSize()
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
            .lcGlassButton(prominent: true).controlSize(.large).tint(coordinator.isRunning ? LC.danger : LC.accent)
            .disabled(coordinator.isTransitioning)
            .fixedSize()
            .accessibilityIdentifier("overview-toggle-listening")
        }
        .lcCard()
    }

    /// One line on whether the next session can start, linking to the first thing to fix.
    @ViewBuilder private func readinessLine(_ readiness: SettingsReadiness) -> some View {
        let language = coordinator.settings.language
        if let first = readiness.blockers.first {
            let names = readiness.blockers.map { SettingsReadiness.title($0.item, language: language) }.joined(separator: b(", ", "、"))
            Button { open(first.item) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(b("\(readiness.blockers.count) to set up: \(names)", "\(readiness.blockers.count) 项待配置：\(names)"))
                    Image(systemName: "arrow.right").font(.caption.weight(.semibold))
                }
                .font(.callout.weight(.medium)).foregroundStyle(LC.warning)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("overview-readiness")
        } else if let first = readiness.pending.first {
            Button { open(first.item) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(LC.success)
                    Text(b("Ready to start", "可以开始")).foregroundStyle(.primary)
                    Text("·").foregroundStyle(.secondary)
                    Text(SettingsReadiness.title(first.item, language: language) + b(" needs setup", "待配置")).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("overview-readiness")
        } else {
            Label(b("Ready to start", "可以开始"), systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(LC.success)
                .accessibilityIdentifier("overview-readiness")
        }
    }

    /// Mode and scenario together: what the next session listens to and how it answers.
    private var conversationTile: some View {
        LCStatTile(title: b("Modes & Scenarios", "模式与场景"), value: t(coordinator.settings.mode.rawValue) + " · " + t(coordinator.settings.scenario.rawValue),
                   detail: modeShortHint(coordinator.settings.mode),
                   systemImage: scenarioSymbol(coordinator.settings.scenario), tone: .accent, detailLineLimit: nil) {
            if locked {
                Text(b("Stop listening to change", "停止监听后可更改")).font(.callout).foregroundStyle(.secondary)
            } else {
                overviewLink(b("Change", "更改")) { page = .modesAndScenarios }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview-mode")
    }
    private func modeShortHint(_ mode: OperatingMode) -> String {
        mode == .remote ? b("only the other side triggers answers", "仅对方提问触发回答")
                        : b("anyone in the room can trigger answers", "现场任何人提问都可触发")
    }

    /// Jev Mode gets its own look: the wordmark, a brand-tinted surface while on, and its switch.
    private func jevTile(_ entry: SettingsReadiness.Entry) -> some View {
        let on = coordinator.settings.automaticSuggestions
        let summary = jevSummary(entry)
        let shape = RoundedRectangle(cornerRadius: LC.Radius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(on ? AnyShapeStyle(LC.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.5)), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(b("Auto answers", "自动回答")).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                LCSwitch(title: "Jev Mode", isOn: $coordinator.settings.automaticSuggestions)
                    .accessibilityIdentifier("overview-jev-mode")
            }
            Text("Jev Mode").font(.custom(AppBrandTitle.fontName, size: 24))
                .foregroundStyle(on ? AnyShapeStyle(LC.brandGradient) : AnyShapeStyle(Color.secondary))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(summary.text).font(.caption).foregroundStyle(summary.warning ? LC.warning : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            overviewLink(b("Adjust", "调整")) { serviceRole = ServiceRole.answerTriggers.rawValue; page = .services }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                LC.surface
                if on {
                    LinearGradient(colors: [LC.accent.opacity(0.10), LC.accentPink.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .clipShape(shape)
        }
        .overlay {
            shape.strokeBorder(on ? AnyShapeStyle(LinearGradient(colors: [LC.accent.opacity(0.55), LC.accentPink.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                  : AnyShapeStyle(LC.hairline), lineWidth: on ? 1.2 : 1)
        }
        .shadow(color: (on ? LC.accentPink : Color.black).opacity(on ? 0.12 : 0.05), radius: on ? 10 : 4, y: 2)
        .lcAnimation(LC.Motion.standard, value: on)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview-jev")
    }
    private var autoPill: some View {
        LCPill(text: coordinator.settings.automaticSuggestions ? b("Auto answers on", "自动建议已开") : b("Auto answers off", "自动建议已关"),
               tone: coordinator.settings.automaticSuggestions ? .accent : .neutral).fixedSize()
    }
    private func speechTile(_ entry: SettingsReadiness.Entry) -> some View {
        LCStatTile(title: b("Speech", "语音识别"),
                   value: t(coordinator.settings.listeningService.label),
                   detail: entry.reason ?? (coordinator.settings.listeningService.isLocal ? b("Runs on this Mac · no API fees", "在本机运行 · 无 API 费用") : b("Cloud · usage-based", "云端 · 按量计费")),
                   systemImage: "waveform", tone: .accent, badge: entry.badge(coordinator.settings.language)) {
            overviewLink(b("Configure", "去设置")) { open(.speech) }
        }
    }

    private func answerTile(_ entry: SettingsReadiness.Entry) -> some View {
        let model = coordinator.settings.analysisModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return LCStatTile(title: b("Answers", "回答模型"),
                          value: model.isEmpty ? t(coordinator.settings.reasoningService.label) : model,
                          detail: entry.reason ?? t(coordinator.settings.reasoningService.label),
                          systemImage: "sparkles", tone: .pink, badge: entry.badge(coordinator.settings.language)) {
            overviewLink(b("Configure", "去设置")) { open(.answers) }
        }
    }

    private func knowledgeTile(_ entry: SettingsReadiness.Entry) -> some View {
        let documents = coordinator.knowledgeDocuments
        let chunks = documents.reduce(0) { $0 + $1.chunkCount }
        let detail: String = documents.isEmpty ? b("Import documents to ground answers.", "导入资料，让回答有据可依。")
            : entry.needsSetup ? (entry.reason ?? "") : b("\(chunks) evidence chunks · \(t(coordinator.settings.knowledgeMode.label))", "\(chunks) 个证据片段 · \(t(coordinator.settings.knowledgeMode.label))")
        return LCStatTile(title: b("Knowledge base", "知识库"),
                          value: b("\(documents.count) documents", "\(documents.count) 份资料"),
                          detail: detail, systemImage: "books.vertical", tone: .success,
                          badge: entry.badge(coordinator.settings.language)) {
            if entry.needsSetup {
                overviewLink(b("Fix", "去处理")) { open(.knowledge) }
            } else {
                overviewLink(b("Open knowledge", "管理资料")) { page = .knowledge }
            }
        }
    }

    private func permissionsTile(_ entry: SettingsReadiness.Entry) -> some View {
        let microphone = permissions.microphone == .authorized
        let granted = (microphone ? 1 : 0) + (permissions.screenAudio ? 1 : 0)
        return LCStatTile(title: b("Permissions", "权限"),
                          value: b("\(granted) of 2 granted", "已授权 \(granted) / 2"),
                          detail: entry.reason ?? (b("Microphone ", "麦克风 ") + (microphone ? "✓" : "—") + b(" · System audio ", " · 系统音频 ") + (permissions.screenAudio ? "✓" : "—")),
                          systemImage: "lock.shield", tone: .warning, badge: entry.badge(coordinator.settings.language)) {
            overviewLink(b("Review", "查看")) { open(.permissions) }
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
        LCSettingsCard(b("Recent sessions", "最近会话"), systemImage: "clock.arrow.circlepath") {
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
        } accessory: {
            if !recent.isEmpty { overviewLink(b("All history", "全部记录")) { page = .history } }
        }
    }
}

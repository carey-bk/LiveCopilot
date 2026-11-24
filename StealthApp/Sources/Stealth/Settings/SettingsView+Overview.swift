import SwiftUI
import AVFoundation

/// Readiness at a glance. Every value comes from live app state; nothing is estimated.
extension SettingsView {
    var overview: some View {
        let readiness = readiness
        return VStack(alignment: .leading, spacing: 16) {
            sessionCard(readiness)
            if !readiness.canStart { guideCard(readiness) }
            // How the next session listens and answers, with what that means in practice.
            HStack(alignment: .top, spacing: 14) {
                conversationTile(title: b("Mode", "模式"), value: t(coordinator.settings.mode.rawValue),
                                 hint: modeHint(coordinator.settings.mode), systemImage: modeSymbol(coordinator.settings.mode),
                                 identifier: "overview-mode")
                conversationTile(title: b("Scenario", "场景"), value: t(coordinator.settings.scenario.rawValue),
                                 hint: scenarioHint(coordinator.settings.scenario), systemImage: scenarioSymbol(coordinator.settings.scenario),
                                 identifier: "overview-scenario")
            }
            .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                speechTile(readiness[.speech]).lcHoverable(radius: LC.Radius.card, lift: true)
                answerTile(readiness[.answers]).lcHoverable(radius: LC.Radius.card, lift: true)
                knowledgeTile(readiness[.knowledge]).lcHoverable(radius: LC.Radius.card, lift: true)
                permissionsTile(readiness[.permissions]).lcHoverable(radius: LC.Radius.card, lift: true)
            }
            recentSessions
            if readiness.canStart { guideCard(readiness) }
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { permissions.refresh() }
    }

    private func sessionCard(_ readiness: SettingsReadiness) -> some View {
        HStack(alignment: .center, spacing: 14) {
            LCIconTile(systemImage: coordinator.isRunning ? "waveform" : "waveform.slash", tone: coordinator.isRunning ? .success : .neutral, size: 40, filled: coordinator.isRunning)
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
            .buttonStyle(.borderedProminent).controlSize(.large).tint(coordinator.isRunning ? LC.danger : LC.accent)
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

    /// The setup guide: prominent while something blocks listening, a quiet row once all is set.
    private func guideCard(_ readiness: SettingsReadiness) -> some View {
        let prominent = !readiness.canStart
        return HStack(alignment: .center, spacing: 12) {
            LCIconTile(systemImage: "sparkles.rectangle.stack", tone: prominent ? .accent : .neutral, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(b("Setup guide", "新手引导")).font(.callout.weight(.semibold))
                Text(prominent
                     ? b("Walks through language, models, services and permissions step by step.", "一步步完成语言、模型、服务和权限设置。")
                     : b("Review language, models, services and permissions. Your setup is kept.", "重新查看语言、模型、服务和权限，已有配置会保留。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(b("Floating window tips", "悬浮窗操作提示")) { coordinator.onShowOverlayTips?() }
                .accessibilityIdentifier("settings-overlay-tips")
            Group {
                if prominent {
                    Button(b("Open guide", "打开引导")) { coordinator.onOpenOnboarding?() }.buttonStyle(.borderedProminent)
                } else {
                    Button(b("Open guide", "打开引导")) { coordinator.onOpenOnboarding?() }
                }
            }
            .accessibilityIdentifier("settings-open-onboarding")
        }
        .fixedSize(horizontal: false, vertical: true)
        .modifier(GuideCardStyle(prominent: prominent))
    }

    private func conversationTile(title: String, value: String, hint: String, systemImage: String, identifier: String) -> some View {
        LCStatTile(title: title, value: value, detail: hint, systemImage: systemImage, tone: .accent, detailLineLimit: nil) {
            if locked {
                Text(b("Stop listening to change", "停止监听后可更改")).font(.callout).foregroundStyle(.secondary)
            } else {
                overviewLink(b("Change", "更改")) { page = .modesAndScenarios }
            }
        }
        .frame(maxHeight: .infinity)
        .lcHoverable(radius: LC.Radius.card, lift: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
    private var autoPill: some View {
        LCPill(text: coordinator.settings.automaticSuggestions ? b("Auto answers on", "自动建议已开") : b("Auto answers off", "自动建议已关"),
               tone: coordinator.settings.automaticSuggestions ? .accent : .neutral).fixedSize()
    }
    private func speechTile(_ entry: SettingsReadiness.Entry) -> some View {
        LCStatTile(title: b("Speech recognition", "语音识别"),
                   value: t(coordinator.settings.listeningService.label),
                   detail: entry.reason ?? (coordinator.settings.listeningService.isLocal ? b("Runs on this Mac · no API fees", "在本机运行 · 无 API 费用") : b("Cloud · usage-based", "云端 · 按量计费")),
                   systemImage: "waveform", tone: .accent, badge: entry.badge(coordinator.settings.language)) {
            overviewLink(b("Configure", "去设置")) { open(.speech) }
        }
    }

    private func answerTile(_ entry: SettingsReadiness.Entry) -> some View {
        let model = coordinator.settings.analysisModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return LCStatTile(title: b("Answer model", "回答模型"),
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

/// Accent-tinted while setup is unfinished; a plain card afterwards.
private struct GuideCardStyle: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if prominent { content.lcCallout(.accent, padding: 16) } else { content.lcCard(padding: 14) }
    }
}

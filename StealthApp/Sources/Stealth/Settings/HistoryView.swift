import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HistoryView: View {
    @ObservedObject var coordinator: AppCoordinator
    var body: some View {
        HistoryBrowser(sessions: coordinator.sessions, english: !coordinator.settings.language.usesChinese, language: coordinator.settings.language,
                       rename: coordinator.renameSession, regenerate: coordinator.regenerateSessionTitle)
            .environment(\.locale, coordinator.settings.language.locale)
    }
}

/// Also hosts isolated acceptance fixtures without opening the user's history store.
struct HistoryBrowser: View {
    @ObservedObject var sessions: SessionStore
    var english = false
    var language: AppLanguage = .simplifiedChinese
    var rename: ((UUID, String) -> Void)? = nil
    var regenerate: ((UUID) -> Void)? = nil
    @State private var pendingRename: SessionRecord?
    @State private var titleDraft = ""
    @State private var query = ""
    @State private var selectedID: UUID?
    @Namespace private var selectionNamespace
    @State private var pendingDelete: SessionRecord?
    @State private var exportError: String?
    @State private var copied = false
    @State private var bookmarks: [UUID: String] = [:]
    private func b(_ en: String, _ zh: String) -> String { english ? en : language.interfaceText(zh) }
    private var filtered: [SessionRecord] { sessions.sessions.filter { $0.matches(query) } }
    private var selected: SessionRecord? { filtered.first { $0.id == selectedID } }
    private func group(_ session: SessionRecord) -> Int {
        Calendar.current.isDateInToday(session.startedAt) ? 0 : Calendar.current.isDateInYesterday(session.startedAt) ? 1 : 2
    }
    var body: some View {
        HStack(spacing: 0) {
            sessionList
            Divider()
            if let session = selected {
                detail(session).id(session.id)
            } else {
                empty(icon: query.isEmpty ? "clock" : "magnifyingglass",
                      title: query.isEmpty ? b("Your conversations, together", "完整会话，随时回看") : b("No matching sessions", "没有找到相关会话"),
                      text: query.isEmpty ? b("Finish a voice session to save its transcript and answers here.", "结束语音会话后，转写与 AI 回答会保存在这里。") : b("Try another word from a question, answer or source.", "试试问题、回答或引用来源中的其他关键词。"))
            }
        }
        .frame(minWidth: 540, minHeight: 360)
        .background(LC.surface)
        .onAppear { reconcileSelection() }
        .onChange(of: query) { _, _ in reconcileSelection() }
        .onChange(of: filtered.map(\.id)) { _, _ in reconcileSelection() }
        .alert(b("Rename session", "重命名会话"), isPresented: Binding(get: { pendingRename != nil }, set: { if !$0 { pendingRename = nil } })) {
            TextField(b("Session title", "会话名称"), text: $titleDraft)
            Button(b("Cancel", "取消"), role: .cancel) { pendingRename = nil }
            Button(b("Save", "保存")) {
                if let record = pendingRename {
                    if let rename { rename(record.id, titleDraft) }
                    else { sessions.rename(record.id, title: titleDraft) }
                }
                pendingRename = nil
            }.disabled(SessionNaming.clean(titleDraft) == nil)
        } message: { Text(b("Enter a title of 1–80 characters. The conversation content stays unchanged.", "输入 1–80 个字的名称，不会修改会话内容。")) }
        .confirmationDialog(b("Delete this session?", "删除这条会话？"), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button(b("Delete session", "删除会话"), role: .destructive) {
                if let record = pendingDelete { sessions.delete(record); bookmarks[record.id] = nil }
                pendingDelete = nil; reconcileSelection()
            }
            Button(b("Cancel", "取消"), role: .cancel) { pendingDelete = nil }
        } message: { Text(b("The transcript, questions and answers will be removed from local history. This cannot be undone.", "将从本地历史中删除这次会话的转写、问题与回答，删除后无法恢复。")) }
    }
    private func reconcileSelection() {
        if !filtered.contains(where: { $0.id == selectedID }) { selectedID = filtered.first?.id }
    }
    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(b("Search conversations", "搜索会话内容"), text: $query)
                    .textFieldStyle(.plain).accessibilityIdentifier("history-search")
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).help(b("Clear search", "清除搜索")) }
            }.padding(.horizontal, 10).frame(height: 30)
                .background(LC.fill, in: Capsule())
                .padding(10)
            Divider()
            LCScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<3) { index in
                        let records = filtered.filter { group($0) == index }
                        if !records.isEmpty {
                            Text([b("Today", "今天"), b("Yesterday", "昨天"), b("Earlier", "更早")][index])
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.top, 12).padding(.bottom, 3)
                            ForEach(records) { session in
                                Button { selectedID = session.id; copied = false } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(HistoryFormat.date(session.startedAt, english: english, language: language, style: index == 2 ? .abbreviated : .omitted, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                        Text("\(session.durationLabel) · \(session.messageCount) " + b("messages", "条消息"))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                        .background {
                                            if selectedID == session.id {
                                                RoundedRectangle(cornerRadius: LC.Radius.control, style: .continuous).fill(LC.surface)
                                                    .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
                                                    .overlay(RoundedRectangle(cornerRadius: LC.Radius.control, style: .continuous).strokeBorder(LC.hairline))
                                                    .matchedGeometryEffect(id: "history-selection", in: selectionNamespace)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                        .lcHoverable(radius: LC.Radius.control)
                                }.buttonStyle(.plain).accessibilityIdentifier("history-session-" + session.id.uuidString)
                                    .contextMenu {
                                        Button(b("Rename…", "重命名…")) { titleDraft = session.title; pendingRename = session }
                                        Button(b("Generate title again", "重新自动命名")) { regenerate?(session.id) }
                                            .disabled(regenerate == nil || session.namingState == "pending" || session.namingInput.isEmpty)
                                        Divider()
                                        Button(b("Copy session", "复制完整会话")) { copy(session.export(markdown: false)) }
                                        Menu(b("Export", "导出")) { exportButtons(session) }
                                        Divider()
                                        Button(b("Delete…", "删除…"), role: .destructive) { pendingDelete = session }
                                    }
                            }
                        }
                    }
                }.padding(.horizontal, 7).padding(.bottom, 12)
                .lcAnimation(LC.Motion.standard, value: selectedID)
            }
            Text("\(filtered.count) " + b("sessions", "条会话")).font(.caption2).foregroundStyle(.secondary).padding(8)
        }.frame(width: 196).background(LC.canvas)
    }
    private func detail(_ session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Text(session.title).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 12) {
                        Button { copy(session.export(markdown: false)); copied = true } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                            .help(b("Copy session", "复制完整会话")).accessibilityLabel(b("Copy session", "复制完整会话"))
                        Menu { exportButtons(session) } label: { Image(systemName: "square.and.arrow.up") }
                            .menuStyle(.borderlessButton).fixedSize().help(b("Export", "导出")).accessibilityIdentifier("export-transcript")
                        Button { pendingDelete = session } label: { Image(systemName: "trash") }
                            .help(b("Delete session", "删除会话")).accessibilityLabel(b("Delete session", "删除会话"))
                    }.buttonStyle(.borderless).foregroundStyle(.secondary).padding(.top, 3)
                }
                Text(HistoryFormat.date(session.startedAt, english: english, language: language, style: .complete, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                Text(HistoryFormat.date(session.startedAt, english: english, language: language) + " – " + HistoryFormat.date(session.endedAt, english: english, language: language) + " · \(session.durationLabel) · \(session.messageCount) " + b("messages", "条消息"))
                    .font(.caption).foregroundStyle(.secondary)
                if session.namingState == "pending" { Text(b("Naming this session…", "正在生成会话名称…")).font(.caption2).foregroundStyle(.secondary) }
                if session.namingState == "failed" { Text(b("Could not generate a title. Your previous title is kept. Check the analysis service and try again from the context menu.", "自动命名失败，已保留原名称。请检查分析服务，再从右键菜单重试。")).font(.caption).foregroundStyle(LC.warning) }
                if let error = exportError ?? sessions.lastError { Text(error).font(.caption).foregroundStyle(LC.danger) }
                HistorySessionStats(session: session, english: english, language: language).padding(.top, 6)
            }.padding(18)
            Divider()
            HistoryTimeline(session: session, english: english, language: language,
                            position: Binding(get: { bookmarks[session.id] }, set: { bookmarks[session.id] = $0 }))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private func exportButtons(_ session: SessionRecord) -> some View {
        Button("Markdown (.md)") { export(session, markdown: true) }
        Button("TXT (.txt)") { export(session, markdown: false) }
    }
    private func export(_ session: SessionRecord, markdown: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = markdown ? [UTType(filenameExtension: "md") ?? .plainText] : [.plainText]
        panel.nameFieldStringValue = markdown ? String(session.exportFilename.dropLast(4)) + ".md" : session.exportFilename
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try sessions.export(session, to: url); exportError = nil } catch { exportError = error.localizedDescription }
        }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func empty(icon: String, title: String, text: String) -> some View {
        LCEmptyState(systemImage: icon, title: title, message: text)
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Real counts for one session and when speech, questions and answers happened.
private struct HistorySessionStats: View {
    let session: SessionRecord
    let english: Bool
    let language: AppLanguage
    private func b(_ en: String, _ zh: String) -> String { english ? en : language.interfaceText(zh) }
    var body: some View {
        let events = session.timeline
        let questions = events.filter { $0.kind == .question }.count
        let answers = events.filter { $0.kind == .answer }.count
        let speech = events.filter { $0.kind == .room || $0.kind == .nearby || $0.kind == .own }.count
        let sources = Set((session.answers ?? []).flatMap { $0.sources.map(\.label) }).count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                stat(b("Duration", "时长"), session.durationLabel)
                stat(b("Speech", "转写"), "\(speech)")
                stat(b("Questions", "问题"), "\(questions)")
                stat(b("Answers", "回答"), "\(answers)")
                stat(b("Sources", "引用来源"), "\(sources)")
            }
            if events.count > 1 { HistoryActivityStrip(session: session, events: events) }
        }
    }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Dot columns across the session: speech density in blue, questions and answers in pink.
private struct HistoryActivityStrip: View {
    let session: SessionRecord
    let events: [SessionEvent]
    private let columns = 40, rows = 4
    var body: some View {
        let start = session.startedAt.timeIntervalSince1970
        let span = max(session.endedAt.timeIntervalSince1970 - start, 1)
        var speech = Array(repeating: 0, count: columns), asked = Array(repeating: false, count: columns)
        for event in events {
            let column = min(columns - 1, max(0, Int((event.at.timeIntervalSince1970 - start) / span * Double(columns))))
            if event.kind == .question || event.kind == .answer { asked[column] = true } else { speech[column] += 1 }
        }
        let peak = max(speech.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<columns, id: \.self) { column in
                let filled = speech[column] == 0 ? 0 : max(1, Int((Double(speech[column]) / Double(peak) * Double(rows)).rounded()))
                VStack(spacing: 2) {
                    ForEach((0..<rows).reversed(), id: \.self) { row in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(row < filled ? LC.accent.opacity(0.35 + 0.65 * Double(row + 1) / Double(rows))
                                  : asked[column] && row == 0 ? LC.accentPink : LC.accent.opacity(0.08))
                            .frame(height: 5)
                    }
                }
            }
        }
        .frame(maxWidth: 420)
        .accessibilityHidden(true)
    }
}

private struct HistoryTimeline: View {
    let session: SessionRecord
    let english: Bool
    let language: AppLanguage
    private func b(_ en: String, _ zh: String) -> String { english ? en : language.interfaceText(zh) }
    @Binding var position: String?
    @State private var visibleID: String?
    init(session: SessionRecord, english: Bool, language: AppLanguage, position: Binding<String?>) {
        self.session = session; self.english = english; self.language = language; _position = position
        _visibleID = State(initialValue: position.wrappedValue)
    }
    var body: some View {
        let events = session.timeline
        LCScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if (session.answers ?? []).isEmpty {
                    Label(session.isLegacy ? b("This older record contains transcripts only.", "这条旧记录仅保存了语音转写，没有 AI 回答。") : b("No AI answers in this session.", "本次会话没有生成 AI 回答。"), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 4).id("notice")
                }
                ForEach(events) { event in
                    HistoryMessage(event: event, english: english, language: language).id(event.id)
                }
            }.scrollTargetLayout().padding(18)
        }.scrollPosition(id: $visibleID, anchor: .top).onDisappear { position = visibleID }.accessibilityIdentifier("history-timeline")
    }
}

private struct HistoryMessage: View {
    let event: SessionEvent
    let english: Bool
    let language: AppLanguage
    private func b(_ en: String, _ zh: String) -> String { english ? en : language.interfaceText(zh) }
    private var color: Color { event.kind == .room ? LC.success : event.kind == .nearby ? LC.accent : Color.secondary }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(language.interfaceText(event.role(english: english))).fontWeight(.medium)
                Text(HistoryFormat.date(event.at, english: english, language: language, time: .standard)).foregroundStyle(Color.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(event.exported(markdown: false, english: english), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).foregroundStyle(Color.secondary).help(b("Copy message", "复制这条消息")).accessibilityLabel(b("Copy message", "复制这条消息"))
            }.font(.caption).foregroundStyle(color)
            if event.kind == .answer {
                ForEach(Array(SuggestionParser.sections(event.content).enumerated()), id: \.offset) { _, section in
                    if AnswerMessageView.isEvidence(section.title) {
                        DisclosureGroup(b("Evidence & notes", "依据与补充")) { markdown(section.content).padding(.top, 6) }.font(.caption)
                    } else {
                        if !section.title.isEmpty { Text(section.title).font(.subheadline.weight(.semibold)) }
                        HighlightedAnswerText(content: section.content, fontSize: 13)
                    }
                }
                if let answer = event.answer {
                    if event.content.isEmpty || answer.state != "completed" {
                        Text(status(answer.state)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let warning = answer.warning { Text(warning).font(.caption).foregroundStyle(LC.warning) }
                    if let error = answer.error { Text(error).font(.caption).foregroundStyle(LC.danger) }
                    if !answer.sources.isEmpty {
                        DisclosureGroup(b("Knowledge sources & citations (\(answer.sources.count))", "知识库来源与引用（\(answer.sources.count)）")) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(answer.sources) { source in
                                    Text(source.label).font(.caption.weight(.semibold))
                                    Text(source.excerpt).font(.callout).foregroundStyle(.secondary)
                                }
                            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }.font(.caption)
                    }
                }
            } else {
                Text(event.content).font(.system(size: 13, weight: event.kind == .question ? .medium : .regular))
                    .textSelection(.enabled).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(event.kind == .answer || event.kind == .question ? 12 : 0)
            .background(event.kind == .answer ? LC.well : event.kind == .question ? LC.accent.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: LC.Radius.control + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LC.Radius.control + 2, style: .continuous).strokeBorder(event.kind == .answer ? LC.hairline : .clear))
            .contextMenu { Button(b("Copy message", "复制这条消息")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(event.exported(markdown: false, english: english), forType: .string) } }
    }
    private func markdown(_ value: String) -> some View { Text(.init(value)).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
    private func status(_ value: String) -> String {
        switch value {
        case "completed": return b("Completed without text", "已结束，未返回正文")
        case "failed": return b("Answer failed", "回答生成失败")
        case "interrupted": return b("Answer interrupted", "回答已中断")
        default: return b("Answer was not completed when saved", "保存时回答尚未完成")
        }
    }
}

private enum HistoryFormat {
    static func date(_ date: Date, english: Bool, language: AppLanguage = .simplifiedChinese, style: Date.FormatStyle.DateStyle = .omitted, time: Date.FormatStyle.TimeStyle = .shortened) -> String {
        date.formatted(Date.FormatStyle(date: style, time: time, locale: (english ? Locale(identifier: "en_US") : language.locale)))
    }
}

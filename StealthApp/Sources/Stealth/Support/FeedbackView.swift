import SwiftUI
import AppKit

enum FeedbackKind: String, CaseIterable, Identifiable {
    case freeze, crash, noTranscript, badAnswer, other
    var id: String { rawValue }
    func label(_ language: AppLanguage) -> String {
        switch self {
        case .freeze: return ServiceGuide.text("Freeze", "卡死", language)
        case .crash: return ServiceGuide.text("Quit unexpectedly", "闪退", language)
        case .noTranscript: return ServiceGuide.text("No transcript", "没有转写", language)
        case .badAnswer: return ServiceGuide.text("Answer problem", "回答出错", language)
        case .other: return ServiceGuide.text("Other", "其他", language)
        }
    }
}

/// One part of the feedback ZIP. Everything is read locally; nothing is sent by the app.
struct FeedbackItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let files: [String: Data]
    let sensitive: Bool
    var included = true
    var preview: String {
        files.sorted { $0.key < $1.key }.map { name, data in
            "── \(name) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))\n" + String(decoding: data.prefix(6000), as: UTF8.self)
        }.joined(separator: "\n\n")
    }
}

enum FeedbackCollector {
    struct Context: Sendable {
        let settings: AppSettings
        let hasLiveKey: Bool
        let hasAnalysisKey: Bool
        let modelHealth: [String]
        let displays: Int
        let language: AppLanguage
    }

    @MainActor static func context(_ coordinator: AppCoordinator) -> Context {
        Context(settings: coordinator.settings, hasLiveKey: coordinator.hasAPIKey, hasAnalysisKey: coordinator.hasAnalysisKey,
                modelHealth: coordinator.localModels.health.sorted { $0.key.rawValue < $1.key.rawValue }.map { $0.value.diagnostic(kind: $0.key) },
                displays: NSScreen.screens.count, language: coordinator.settings.language)
    }

    /// Reads logs, event history, stall stacks and system reports near `date`. Runs off the main thread.
    static func collect(_ context: Context, near date: Date) -> [FeedbackItem] {
        func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, context.language) }
        let summary = DiagnosticReport.make(settings: context.settings) + "\n\n" + DiagnosticReport.systemState(displays: context.displays)
            + "\n\n" + DiagnosticReport.serviceSettings(context.settings, hasLiveKey: context.hasLiveKey, hasAnalysisKey: context.hasAnalysisKey)
            + "\n\n### Local model self-checks\n" + (context.modelHealth.isEmpty ? "None run in this process." : context.modelHealth.joined(separator: "\n\n"))
        var items = [FeedbackItem(id: "summary", title: b("Summary", "摘要"),
                                  detail: b("Version, macOS, hardware, memory, settings (no keys) and model checks.", "版本、系统、硬件、内存、设置（不含密钥）和模型自检结果。"),
                                  files: ["summary.txt": Data(summary.utf8)], sensitive: false)]

        let logFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LiveCopilot")
        var logs = [String: Data]()
        for name in ["livecopilot.log", "livecopilot.1.log"] {
            if let data = try? Data(contentsOf: logFolder.appendingPathComponent(name)) { logs["logs/" + name] = data }
        }
        if !logs.isEmpty {
            items.append(FeedbackItem(id: "logs", title: b("App log", "运行日志"),
                                      detail: b("Timings and errors of listening, recognition and answers; no conversation text.", "监听、识别和回答各环节的时间与错误，不含对话内容。"),
                                      files: logs, sensitive: false))
        }
        items.append(FeedbackItem(id: "events", title: b("Capture events", "采集事件记录"),
                                  detail: b("Start, stop, audio checks and freeze detections of recent sessions.", "最近几次监听的开始、停止、音频检查和卡顿记录。"),
                                  files: ["events.json": CaptureDiagnostics.journal()], sensitive: false))

        let stallFiles = ((try? FileManager.default.contentsOfDirectory(at: StackReport.directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("stall-") }
        var stalls = [String: Data]()
        for file in stallFiles { if let data = try? Data(contentsOf: file) { stalls["stalls/" + file.lastPathComponent] = data } }
        if !stalls.isEmpty {
            items.append(FeedbackItem(id: "stalls", title: b("Freeze stacks (\(stalls.count))", "卡顿调用栈（\(stalls.count) 份）"),
                                      detail: b("Where the app was stuck when it stopped responding.", "软件无响应时卡在哪里。"),
                                      files: stalls, sensitive: false))
        }

        let reports = DiagnosticBundle.systemReports(near: date)
        if !reports.isEmpty {
            var files = [String: Data]()
            for report in reports { files["system-reports/" + report.name] = report.data }
            items.append(FeedbackItem(id: "reports", title: b("macOS reports (\(reports.count))", "系统报告（\(reports.count) 份）"),
                                      detail: b("Crash, hang and CPU reports macOS wrote within 3 days of that time. They can include your username and file paths.",
                                                "macOS 在该时间前后 3 天内生成的崩溃、卡顿和 CPU 报告，可能包含用户名和文件路径。"),
                                      files: files, sensitive: true))
        }
        return items
    }
}

@MainActor
enum FeedbackMailer {
    /// Opens a draft in the user's mail app with the ZIP attached. False if no mail app can take it.
    static func compose(to recipient: String, subject: String, body: String, attachment: URL) -> Bool {
        guard let service = NSSharingService(named: .composeEmail) else { return false }
        service.recipients = [recipient]
        service.subject = subject
        let items: [Any] = [body, attachment]
        guard service.canPerform(withItems: items) else { return false }
        service.perform(withItems: items)
        return true
    }

    /// A draft without the attachment, for mail apps the sharing service cannot reach.
    static func mailto(to recipient: String, subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"; components.path = recipient
        components.queryItems = [.init(name: "subject", value: subject), .init(name: "body", value: body)]
        return components.url
    }
}

struct FeedbackView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var kind = FeedbackKind.freeze
    @State private var happenedAt = Date()
    @State private var notes = ""
    @State private var items: [FeedbackItem]?
    @State private var recipient = SupportContact.defaultEmail
    @State private var working = false
    @State private var savedZIP: URL?
    @State private var message = ""
    private var language: AppLanguage { coordinator.settings.language }
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(b("Report a problem", "反馈问题")).font(.title2.weight(.semibold))
                Text(b("LiveCopilot packs the diagnostics below into a ZIP and opens an email to the author with it attached. Nothing is sent until you press Send. No audio, conversation, answers, documents or keys are included.",
                       "LiveCopilot 会把下面的诊断信息打包成 ZIP，并打开一封已附上它的邮件，收件人是作者。你点「发送」之前不会发出任何内容。不包含录音、对话、回答、资料或密钥。"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LCSettingsCard(b("What happened", "发生了什么"), systemImage: "exclamationmark.bubble") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(b("Problem", "问题类型"), selection: $kind) {
                        ForEach(FeedbackKind.allCases) { Text($0.label(language)).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("feedback-kind")
                    DatePicker(b("About when", "大约什么时候"), selection: $happenedAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("feedback-time")
                    Text(b("What were you doing? Meeting app, microphone or headset, and anything you noticed. Do not include keys or meeting contents.",
                           "当时在做什么？用的会议软件、麦克风或耳机，以及注意到的现象。不要填写密钥或会议内容。"))
                        .font(.caption).foregroundStyle(.secondary)
                    DiagnosticNotesEditor(text: $notes).frame(height: 76)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LC.hairline))
                        .accessibilityIdentifier("diagnostics-reproduction")
                }
            }
            LCSettingsCard(b("Included in the ZIP", "打包内容"), systemImage: "archivebox") {
                if let items {
                    LCScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(items.indices, id: \.self) { index in itemRow(index) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 120, maxHeight: .infinity)
                } else {
                    HStack { ProgressView().controlSize(.small); Text(b("Collecting diagnostics…", "正在收集诊断信息…")).font(.callout) }
                }
            }
            if let savedZIP { resultRow(savedZIP) }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button(b("Close", "关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(b("Report on GitHub instead", "改为在 GitHub 反馈")) { openGitHub() }
                    .buttonStyle(.borderless).font(.callout).accessibilityIdentifier("diagnostics-github")
                Spacer()
                Text(b("To ", "发送到 ") + recipient).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if working { ProgressView().controlSize(.small) }
                Button(b("Create ZIP and email", "生成并发邮件")) { send() }
                    .keyboardShortcut(.defaultAction).disabled(items == nil || working)
                    .accessibilityIdentifier("diagnostics-export-zip")
            }
        }
        .padding(24).frame(width: 720, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { recipient = await SupportContact.resolve() }
        .task(id: Int(happenedAt.timeIntervalSince1970 / 600)) { await collect() }
    }

    private func itemRow(_ index: Int) -> some View {
        let item = items![index]
        return VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: Binding(get: { items?[index].included ?? false }, set: { items?[index].included = $0 })) {
                HStack(spacing: 6) {
                    Text(item.title).font(.callout.weight(.medium))
                    if item.sensitive { LCPill(text: b("May contain paths", "可能含路径"), tone: .warning) }
                }
            }.toggleStyle(.checkbox)
            Text(item.detail).font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
            DisclosureGroup(b("Preview", "预览")) {
                ScrollView { Text(item.preview).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 150)
            }.font(.caption).padding(.leading, 20)
        }
    }

    private func resultRow(_ zip: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(LC.success)
            Text(b("Saved ", "已保存 ") + zip.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(b("Show in Finder", "在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([zip]) }
            Button(b("Copy address", "复制邮箱地址")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(recipient, forType: .string)
                message = b("Address copied. Attach the ZIP shown in Finder to your email.", "已复制邮箱地址。请在邮件中附上访达里显示的 ZIP。")
            }
            Button(b("Other mail app", "用其他邮件 App")) { openMailto(zip) }
        }.font(.caption).buttonStyle(.borderless)
    }

    private func collect() async {
        let context = FeedbackCollector.context(coordinator), date = happenedAt
        let previous = Dictionary(uniqueKeysWithValues: (items ?? []).map { ($0.id, $0.included) })
        var collected = await Task.detached(priority: .utility) { FeedbackCollector.collect(context, near: date) }.value
        for index in collected.indices { collected[index].included = previous[collected[index].id] ?? true }
        items = collected
    }

    private var subject: String {
        let time = happenedAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
        return "LiveCopilot \(AppInfo.display) · \(kind.label(language)) · \(time)"
    }

    private func body(zipName: String) -> String {
        let included = (items ?? []).filter(\.included).map(\.title).joined(separator: ", ")
        return """
        \(b("Problem", "问题类型")): \(kind.label(language))
        \(b("When", "发生时间")): \(happenedAt.formatted(date: .abbreviated, time: .shortened)) (\(TimeZone.current.identifier))
        \(b("Version", "版本")): \(AppInfo.diagnostic) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)

        \(b("Description", "描述")):
        \(notes.isEmpty ? "—" : String(notes.prefix(2000)))

        \(b("Included", "诊断包内容")): \(included)
        \(b("Attachment", "附件")): \(zipName)
        """
    }

    private func send() {
        guard let items else { return }
        let files = items.filter(\.included).reduce(into: [String: Data]()) { result, item in result.merge(item.files) { first, _ in first } }
        let feedback = "Problem: \(kind.rawValue)\nHappened at: \(ISO8601DateFormatter().string(from: happenedAt)) (\(TimeZone.current.identifier))\nReported at: \(ISO8601DateFormatter().string(from: Date()))\n\n" + String(notes.prefix(12_000))
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)", timeZone: .current, calendar: .current))
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let target = folder.appendingPathComponent("LiveCopilot-feedback-\(stamp).zip")
        working = true; message = ""
        Task {
            do {
                var all = files; all["feedback.txt"] = Data(feedback.utf8)
                try await Task.detached(priority: .utility) { try DiagnosticBundle.write(to: target, files: all) }.value
                savedZIP = target
                if FeedbackMailer.compose(to: recipient, subject: subject, body: body(zipName: target.lastPathComponent), attachment: target) {
                    message = b("A draft with the ZIP attached is open in your mail app. Check it and press Send.", "已在邮件 App 中打开带附件的草稿，确认后点「发送」即可。")
                } else {
                    openMailto(target)
                }
            } catch {
                message = b("Could not create the ZIP. Check free disk space and try again.", "无法生成 ZIP，请检查磁盘空间后重试。")
            }
            working = false
        }
    }

    private func openMailto(_ zip: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([zip])
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(recipient, forType: .string)
        if let url = FeedbackMailer.mailto(to: recipient, subject: subject, body: body(zipName: zip.lastPathComponent)), NSWorkspace.shared.open(url) {
            message = b("A draft is open without the attachment: drag the ZIP shown in Finder into it. The address is also copied.", "已打开邮件草稿，但无法自动附上：请把访达中显示的 ZIP 拖进邮件。邮箱地址也已复制。")
        } else {
            message = b("No mail app is set up. The ZIP is shown in Finder and the address is copied: send it from your webmail.", "没有可用的邮件 App。ZIP 已在访达中显示，邮箱地址已复制，请用网页邮箱发送。")
        }
    }

    private func openGitHub() {
        let summary = items?.first(where: { $0.id == "summary" }).map { String(decoding: $0.files["summary.txt"] ?? Data(), as: UTF8.self) } ?? ""
        if let url = DiagnosticReport.issueURL(report: String(summary.prefix(4000))) { NSWorkspace.shared.open(url) }
    }
}

/// Explicit text-container insets keep the first baseline clear of the scroll-view border.
struct DiagnosticNotesEditor: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = NSTextView(frame: .zero)
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor; editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text; editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Problem description")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = view.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DiagnosticNotesEditor
        init(_ parent: DiagnosticNotesEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            let bounded = String(editor.string.prefix(12_000))
            if editor.string != bounded { editor.string = bounded }
            parent.text = bounded
        }
    }
}

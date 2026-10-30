import SwiftUI
import UniformTypeIdentifiers

struct DetailedDiagnosticView: View {
    let report: String
    let language: AppLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var scan: DiagnosticBundle.Scan?
    @State private var includeCrashes = false
    @State var notes = ""
    @State private var selected = Set<String>()
    @State private var message = ""
    @State private var exporting = false
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(b("Detailed bug report", "详细故障诊断包")).font(.title2)
            Text(b("Raw macOS crash reports contain full stacks and exception/termination reasons, and may contain usernames, paths and process information. Review and select only reports from the failure. Export locally and share privately; this never uploads or opens GitHub.", "macOS 原始崩溃报告包含完整调用栈、异常及终止原因，也可能包含用户名、路径和进程信息。请预览并只选择故障对应的报告。仅导出到本地、私下提供，不会上传或打开 GitHub。"))
            Text(b("1. Describe the problem → 2. Export ZIP → 3. Send the saved ZIP privately to the author. Closing this window does not export or send anything.", "1. 填写问题 → 2. 导出 ZIP → 3. 将保存的 ZIP 私下发送给作者。关闭窗口不会导出或发送。"))
                .font(.callout)
            Text(b("When did it fail? What did you do? Which microphone/headset? Did the app quit or freeze? Do not enter secrets or meeting contents.", "请填写发生时间、复现步骤、麦克风/耳机类型，以及是退出还是卡死。不要填写密钥或会议内容。"))
                .font(.caption).foregroundStyle(.secondary)
            DiagnosticNotesEditor(text: $notes).frame(height: 90).border(.secondary.opacity(0.3))
                .accessibilityIdentifier("diagnostics-reproduction")
                .onChange(of: notes) { _, value in if value.count > 12_000 { notes = String(value.prefix(12_000)) } }
            if let scan {
                if scan.crashes.isEmpty {
                    Text(b("No matching crash report found. You can still export the event history and reproduction steps.", "未找到相关崩溃报告，仍可导出事件记录和复现步骤。")).font(.callout)
                }
                Text(scan.status).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(scan.crashes) { crash in
                            Toggle("\(crash.id) · \(crash.date.formatted())", isOn: Binding(get: { selected.contains(crash.id) }, set: { if $0 { selected.insert(crash.id) } else { selected.remove(crash.id) } }))
                            DisclosureGroup(b("Preview raw report", "预览原始报告")) {
                                Text(crash.preview).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                                if crash.data.count > 120_000 { Text(b("Preview truncated; export includes the complete selected file. Inspect the exported file before sharing.", "预览已截断，导出包含选中的完整文件。分享前请检查导出文件。")) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity)
                Toggle(b("Include selected raw crash reports; I understand they may contain private information", "包含所选原始崩溃报告；我知道其中可能含隐私信息"), isOn: $includeCrashes)
                    .disabled(selected.isEmpty)
            } else { ProgressView(b("Finding matching crash reports…", "正在查找相关崩溃报告…")) }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            HStack {
                Button(b("Close", "关闭")) { dismiss() }.disabled(exporting)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if exporting { ProgressView().controlSize(.small) }
                Button(b("Export ZIP…", "导出 ZIP…")) { export() }.disabled(scan == nil || exporting)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("diagnostics-export-zip")
            }
        }.padding(24).frame(width: 720, height: 610)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light)
            .task { scan = await Task.detached(priority: .utility) { DiagnosticBundle.scan() }.value }
    }
    private func export() {
        guard let scan else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = "LiveCopilot-support.zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let crashes = includeCrashes ? scan.crashes.filter { selected.contains($0.id) } : []
        let journal = CaptureDiagnostics.journal(), notes = notes, summary = report + "\n\n" + scan.status
        exporting = true; message = ""
        Task {
            do {
                try await Task.detached(priority: .utility) { try DiagnosticBundle.write(to: destination, report: summary, journal: journal, notes: notes, crashes: crashes) }.value
                message = b("ZIP saved and revealed in Finder. Review it, then send it privately to the author. Nothing has been sent automatically.", "ZIP 已保存，并已在访达中显示。请检查文件后私下发送给作者；软件没有自动发送。")
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { message = b("Export failed. Check the destination and free disk space.", "导出失败，请检查保存位置与磁盘空间。") }
            exporting = false
        }
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

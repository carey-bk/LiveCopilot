import Foundation
import AppKit
import SwiftUI

enum DiagnosticReport {
    // Extract only machine identifiers and numeric crash frames; no raw paths, exception messages,
    // registers, process arguments, application-specific information or arbitrary symbol strings.
    static func crashSummary(_ object: [String: Any]) -> String? {
        guard let process = object["procName"] as? String,
              ["LiveCopilot", "LiveCopilot Dev", "livecopilot-inference"].contains(process) else { return nil }
        var result = ["Process: \(process)"]
        if let bundle = object["bundleInfo"] as? [String: Any] {
            for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
                if let value = bundle[key] as? String, value.count <= 40,
                   value.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil {
                    result.append("\(key): \(value)")
                }
            }
        }
        if let exception = object["exception"] as? [String: Any] {
            for key in ["type", "signal"] {
                if let value = exception[key] as? String,
                   ["EXC_BAD_ACCESS", "EXC_CRASH", "EXC_BREAKPOINT", "EXC_RESOURCE", "EXC_GUARD", "SIGABRT", "SIGSEGV", "SIGBUS", "SIGTRAP", "SIGKILL", "SIGILL"].contains(value) {
                    result.append("\(key): \(value)")
                }
            }
        }
        if let index = object["faultingThread"] as? Int,
           let threads = object["threads"] as? [[String: Any]], threads.indices.contains(index),
           let frames = threads[index]["frames"] as? [[String: Any]] {
            let images = object["usedImages"] as? [[String: Any]] ?? []
            for frame in frames.prefix(8) {
                guard let image = frame["imageIndex"] as? Int, let offset = frame["imageOffset"] as? Int else { continue }
                let uuid = images.indices.contains(image) ? (images[image]["uuid"] as? String).flatMap(UUID.init(uuidString:))?.uuidString : nil
                result.append("frame image=\(image) offset=\(offset) uuid=\(uuid ?? "unknown")")
            }
        }
        return result.joined(separator: "\n")
    }
    static func recentCrashes() -> String {
        let scan = DiagnosticBundle.scan()
        let summaries = scan.crashes.compactMap { crash -> String? in
            guard let object = DiagnosticBundle.parse(crash.data), let summary = crashSummary(object) else { return nil }
            return "Report date: \(ISO8601DateFormatter().string(from: crash.date))\n" + summary
        }
        return scan.status + "\n" + (summaries.isEmpty ? "No readable matching crash report found. This does not rule out a crash." : summaries.joined(separator: "\n\n"))
    }
    static func make(settings: AppSettings) -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return """
        ## LiveCopilot diagnostics
        App: \(AppInfo.diagnostic)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Hardware: \(String(cString: model))
        Memory GiB: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        Listening service: \(settings.listeningService.rawValue)
        Capture mode: \(settings.mode.rawValue)
        Knowledge mode: \(settings.knowledgeMode.rawValue)

        Automatic suggestions: \(settings.automaticSuggestions)
        Laya threshold: \(settings.layaThreshold)

        ### Automatic trigger (current process, most recent listening session)
        \(LayaGateDiagnostics.snapshot())

        ### Previous process exit
        \(CaptureDiagnostics.previousExitSummary())

        ### Recent capture boundaries (may include earlier sessions)
        \(CaptureDiagnostics.snapshot())

        ### Recent crash summaries (may belong to older versions)
        \(recentCrashes())
        """
    }
    static func issueURL(report: String) -> URL? {
        var url = URLComponents(string: "https://github.com/carey-bk/LiveCopilot/issues/new")!
        url.queryItems = [.init(name: "title", value: "[Bug] LiveCopilot feedback"),
                          .init(name: "body", value: "## What happened / 发生了什么\n\n## Steps / 复现步骤\n\n" + report)]
        return url.url
    }
}

struct DiagnosticFeedbackView: View {
    let settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var report = ""
    @State private var error = ""
    @State private var showDetailed = false
    private func b(_ en: String, _ zh: String) -> String { ServiceGuide.text(en, zh, settings.language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(b("Send feedback", "反馈问题")).font(.title2)
            Text(b("GitHub Issues are public and require a GitHub account. Review this summary before opening GitHub; you submit it yourself in the browser. No audio, conversation, documents, credentials or raw logs are included.", "GitHub Issue 公开可见，需要 GitHub 账号。请先预览摘要，再到浏览器中自行提交。报告不含录音、对话、知识库、密钥或原始日志。"))
                .font(.callout)
            ScrollView { Text(report.isEmpty ? b("Preparing report…", "正在生成报告…") : report).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            Button(b("Export detailed ZIP for private support…", "导出详细 ZIP，私下反馈（推荐）…")) { showDetailed = true }
                .accessibilityIdentifier("diagnostics-detailed")
            HStack {
                Button(b("Export summary TXT…", "导出摘要 TXT…")) { export() }.disabled(report.isEmpty)
                Button(b("Open GitHub feedback", "在 GitHub 反馈")) {
                    guard let url = DiagnosticReport.issueURL(report: report), NSWorkspace.shared.open(url) else {
                        error = b("Could not open browser. Export the report and visit the project's Issues page.", "无法打开浏览器，请导出报告并访问项目 Issues 页面。"); return
                    }
                }.disabled(report.isEmpty).accessibilityIdentifier("diagnostics-github")
                Spacer()
                Button(b("Close", "关闭")) { dismiss() }
            }
        }.padding(24).frame(width: 680, height: 520)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.light)
            .sheet(isPresented: $showDetailed) { DetailedDiagnosticView(report: report, language: settings.language) }
            .task {
                let snapshot = settings
                report = await Task.detached(priority: .utility) { DiagnosticReport.make(settings: snapshot) }.value
            }
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "LiveCopilot-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = b("Could not save report. Choose another location.", "无法保存报告，请选择其他位置。") }
    }
}

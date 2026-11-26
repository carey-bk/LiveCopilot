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
    /// Memory, swap, disk and display state at export time. Numbers only.
    static func systemState(displays: Int) -> String {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vm = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let page = UInt64(vm_kernel_page_size)
        func mb(_ pages: natural_t) -> String { String(UInt64(pages) * page / 1_048_576) }
        var swap = xsw_usage(); var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        var pressure: Int32 = 0; var pressureSize = MemoryLayout<Int32>.size
        let hasPressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0
        var info = task_vm_info_data_t()
        var infoCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let task = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &infoCount) }
        }
        let disk = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        let pressureName = [1: "normal", 2: "warning", 4: "critical"][Int(pressure)] ?? String(pressure)
        return """
        ### System state at export
        Time zone: \(TimeZone.current.identifier)
        System uptime hours: \(Int(ProcessInfo.processInfo.systemUptime / 3600))
        Memory pressure: \(hasPressure ? pressureName : "unknown")
        Memory MB: \(vm == KERN_SUCCESS ? "free \(mb(stats.free_count)) active \(mb(stats.active_count)) inactive \(mb(stats.inactive_count)) wired \(mb(stats.wire_count)) compressed \(mb(stats.compressor_page_count))" : "unknown")
        Swap MB: \(hasSwap ? "used \(swap.xsu_used / 1_048_576) of \(swap.xsu_total / 1_048_576)" : "unknown")
        App footprint MB: \(task == KERN_SUCCESS ? String(info.phys_footprint / 1_048_576) : "unknown")
        Free disk GB: \(disk.map { String($0 / 1_000_000_000) } ?? "unknown")
        Displays: \(displays)
        Default input is Bluetooth: \(AudioDevices.defaultInputIsBluetooth())
        """
    }
    /// Which services and options are chosen; whether keys exist, never the keys. Endpoint host only.
    static func serviceSettings(_ settings: AppSettings, hasLiveKey: Bool, hasAnalysisKey: Bool) -> String {
        let endpoint = (try? settings.compatibleEndpoint())?.host ?? "none"
        return """
        ### Settings (no keys)
        Scenario: \(settings.scenario.rawValue)
        Answer service: \(settings.reasoningService.rawValue) · model \(settings.reasoningService == .compatible ? settings.compatibleModel : settings.reasoningService == .deepSeek ? settings.deepSeekModel : settings.reasoningModel)
        Compatible endpoint host: \(endpoint)
        Live key saved: \(hasLiveKey) · analysis key saved: \(hasAnalysisKey)
        Embedding service: \(settings.embeddingService.rawValue)
        Answer language: \(settings.answerLanguage.rawValue) · translations: \(settings.effectiveTranslationLanguages.map(\.rawValue).joined(separator: ","))
        Include recent conversation: \(settings.includeConversation)
        Continuous questions: \(settings.continuousQuestionPolicy.rawValue)
        Overlay background: \(settings.background.rawValue) · hidden from capture: \(settings.excludeOverlayFromCapture)
        Interface language: \(settings.language.rawValue)
        """
    }
    static func issueURL(report: String) -> URL? {
        var url = URLComponents(string: "https://github.com/carey-bk/LiveCopilot/issues/new")!
        url.queryItems = [.init(name: "title", value: "[Bug] LiveCopilot feedback"),
                          .init(name: "body", value: "## What happened / 发生了什么\n\n## Steps / 复现步骤\n\n" + report)]
        return url.url
    }
}

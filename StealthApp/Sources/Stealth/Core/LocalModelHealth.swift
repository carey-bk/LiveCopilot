import Foundation
import Darwin

struct LocalModelHealth: Sendable {
    enum Stage: String, Sendable { case ready, files, runtime, load, memory, inference, interrupted }
    let stage: Stage
    let checkedAt: Date
    let checksum: String
    let runtimeCode: String
    var ready: Bool { stage == .ready }
    func advice(english: Bool) -> String {
        switch stage {
        case .ready: return english ? "Self-check passed. If a document still shows an old error, open Knowledge and click Re-index." : "自检通过，可以离线使用。如果文档仍显示以前的错误，请到知识库点击“重建索引”。"
        case .files: return english ? "Model files are missing, unreadable or damaged. Click Download again. Your documents will be kept." : "模型文件缺失、无法读取或已损坏。请点击“重新下载”，知识库文档会保留。"
        case .runtime: return english ? "The app's inference component cannot start. Reinstall the latest complete LiveCopilot app. If it persists, copy diagnostics and send them to support." : "应用的推理组件无法启动。请重新安装最新版完整 LiveCopilot 应用；若仍失败，请复制诊断信息发给支持人员。"
        case .memory: return english ? "Not enough inference memory. Close other large apps, then click Run self-check. If it persists, copy diagnostics for support." : "推理内存分配失败。请关闭其他占内存的应用，再点击“运行自检”；若仍失败，请复制诊断信息发给支持人员。"
        case .load, .inference, .interrupted: return english ? "Files passed verification, but local inference failed. Restart LiveCopilot and run self-check again. If it persists, copy diagnostics for support; repeated downloads are unlikely to help." : "模型文件校验通过，但本地推理未成功。请重启 LiveCopilot 后再次运行自检；若仍失败，请复制诊断信息发给支持人员，不必反复下载模型。"
        }
    }
    func diagnostic(kind: LocalModelKind) -> String {
        func sys(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return "unknown" }
            var value = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "unknown" }
            return String(cString: value)
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let bundle = Bundle.main
        return """
        LiveCopilot local model diagnostics v1
        app: \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") (\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"))
        system: \(ProcessInfo.processInfo.operatingSystemVersionString)
        hardware: \(sys("hw.model"))
        processor: \(sys("machdep.cpu.brand_string"))
        process_arch: \(architecture)
        physical_memory_bytes: \(ProcessInfo.processInfo.physicalMemory)
        model: \(kind.rawValue)
        checked_at: \(ISO8601DateFormatter().string(from: checkedAt))
        stage: \(stage.rawValue)
        checksum: \(checksum)
        runtime_code: \(runtimeCode)
        No document contents, credentials, usernames or file paths included.
        """
    }
}

enum LocalModelSelfCheck {
    static func run(_ kind: LocalModelKind, root: URL, executable: URL? = nil) async throws -> LocalModelHealth {
        func result(_ stage: LocalModelHealth.Stage, _ checksum: String, _ code: String) -> LocalModelHealth {
            .init(stage: stage, checkedAt: Date(), checksum: checksum, runtimeCode: code)
        }
        let directory = kind.location(in: root)
        do {
            // No real user input is read; only the pinned model payloads are hashed.
            try await Task.detached(priority: .utility) {
                for file in kind.downloads {
                    try file.verify(directory.appendingPathComponent(file.installedName ?? file.name))
                }
            }.value
        } catch {
            try Task.checkCancellation()
            return result(.files, "failed", "file_verification_failed")
        }
        try Task.checkCancellation()
        let worker = LocalInferenceWorker(mode: kind == .embedding ? "embedding" : kind == .terminologySpeech ? "zipformer" : "paraformer", modelDirectory: directory, executable: executable)
        defer { worker.close(initiator: .selfCheck) }
        do {
            if kind == .embedding {
                let response = try await worker.call(["op": "embed", "text": "Local model self-check. 本地模型自检。"])
                guard let vector = response["vector"] as? [NSNumber], vector.count == 1024,
                      vector.allSatisfy({ $0.doubleValue.isFinite }),
                      abs(vector.reduce(0) { $0 + $1.doubleValue * $1.doubleValue } - 1) < 0.01 else {
                    return result(.inference, "passed", "invalid_vector")
                }
            } else {
                let response = try await worker.call(["op": "audio", "pcm": Data(repeating: 0, count: 32000).base64EncodedString()])
                guard response["segments"] is [Any], response["partial"] is String else {
                    return result(.inference, "passed", "invalid_audio_response")
                }
            }
            try Task.checkCancellation()
            return result(.ready, "passed", "ok")
        } catch {
            try Task.checkCancellation()
            let code = worker.failureCode
            let stage: LocalModelHealth.Stage
            switch code {
            case "runtime_missing", "runtime_start": stage = .runtime
            case "embedding_context": stage = .memory
            case "embedding_load", "model_load_failed": stage = .load
            case "process_ended", "timeout": stage = .interrupted
            default: stage = .inference
            }
            return result(stage, "passed", code)
        }
    }
}

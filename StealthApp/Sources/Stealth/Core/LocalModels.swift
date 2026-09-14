import Foundation
import CryptoKit

enum ListeningService: String, Codable, CaseIterable, Identifiable {
    case openAI, local
    var id: String { rawValue }
    var label: String { self == .local ? "Local · SenseVoiceSmall + VAD" : "OpenAI · GPT-Live" }
    var sampleRate: Double { self == .local ? 16000 : 24000 }
}

enum EmbeddingService: String, Codable, CaseIterable, Identifiable {
    case openAI, local
    var id: String { rawValue }
    var label: String { self == .local ? "Local · BGE-M3" : "OpenAI Embeddings" }
}

enum LocalModelKind: String, CaseIterable, Identifiable, Sendable {
    case speech, embedding
    var id: String { rawValue }
    var title: String { self == .speech ? "SenseVoiceSmall + Silero VAD" : "BGE-M3 · Q8" }
    var directory: String { self == .speech ? "sensevoice-int8-v1" : "bge-m3-q8-v1" }
    var downloadSize: String { self == .speech ? "164 MB" : "635 MB" }
    static let embeddingIdentity = "local:bge-m3:q8_0:950f4a8e5e19:cls:l2:v1"
    var files: [String] { self == .speech ? ["model.int8.onnx", "tokens.txt", "silero_vad.onnx"] : ["bge-m3-Q8_0.gguf"] }
    func location(in root: URL) -> URL { root.appendingPathComponent(directory, isDirectory: true) }
    func isInstalled(in root: URL) -> Bool {
        let directory = location(in: root)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("installed.json")),
              let sizes = try? JSONDecoder().decode([String: Int64].self, from: data), Set(sizes.keys) == Set(files) else { return false }
        return files.allSatisfy { name in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else { return false }
            return size.int64Value == sizes[name] && size.int64Value > 0
        }
    }
}

struct ModelDownload: Sendable {
    let url: URL
    let sha256: String
    let name: String
    static let senseVoice = Self(
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2")!,
        sha256: "7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e", name: "sensevoice.tar.bz2")
    static let vad = Self(
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")!,
        sha256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6", name: "silero_vad.onnx")
    static let bge = Self(
        url: URL(string: "https://huggingface.co/gpustack/bge-m3-GGUF/resolve/2d48f1737679ad900d5c26c5aad5410e9c70fdca/bge-m3-Q8_0.gguf")!,
        sha256: "950f4a8e5e19477a6d3c26d2f162233c20002c601f75e4b002e3239997821167", name: "bge-m3-Q8_0.gguf")
    func verify(_ file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation(); hash.update(data: block)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw CopilotError.message("Model verification failed. Download it again; the previous model was preserved.")
        }
    }
}

/// Heuristic completion gate for stable local ASR segments. No network or model calls.
/// It deliberately misses ambiguous/rhetorical questions rather than firing on every VAD pause.
enum LocalQuestionDetector {
    static func isQuestion(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard lower.count >= 5 else { return false }
        guard !["不用回答", "不需要回答", "忽略刚才", "never mind", "ignore that", "no need to answer"].contains(where: lower.contains) else { return false }
        let incomplete = [" and", " or", " because", " if", " but", " the", " of", " with", " to", "以及", "因为", "如果", "但是", "然后", "比如", "关于", "对于"]
        guard !incomplete.contains(where: lower.hasSuffix) else { return false }
        let filler = ["thank you", "thanks", "okay", "ok", "right", "you know", "谢谢", "好的", "对吧", "是不是", "明白了"]
        guard !filler.contains(lower) else { return false }
        let reported = ["i don't know", "i do not know", "we don't know", "he asked", "she asked", "我不知道", "他问我", "她问我", "我刚才问"]
        guard !reported.contains(where: lower.hasPrefix) else { return false }
        let english = #"(^|[.!?]\s+)(why|what|how|when|where|which|who|whose|can you|could you|would you|will you|do you|did you|have you|are you|is there|are there|what about|how about|please explain|please describe|tell us|tell me|walk us through|walk me through)\b"#
        if lower.range(of: english, options: .regularExpression) != nil { return true }
        let chinese = ["为什么", "为何", "怎么", "怎样", "如何", "什么", "多少", "哪个", "哪些", "哪里", "是否", "能否", "可否", "能不能", "有没有", "你认为", "你觉得", "您认为", "请介绍", "请解释", "请说明", "请问", "说说", "谈谈"]
        if chinese.contains(where: lower.contains) { return true }
        return (lower.hasSuffix("吗") || lower.hasSuffix("呢")) && lower.count >= 8
    }
}

import Foundation
import CryptoKit

enum ListeningService: String, Codable, CaseIterable, Identifiable {
    case openAI, local, paraformer
    var id: String { rawValue }
    var label: String {
        switch self {
        case .openAI: return "OpenAI · GPT-Live"
        case .local: return "Local · SenseVoiceSmall + VAD"
        case .paraformer: return "Local · Paraformer-zh-streaming"
        }
    }
    var localModel: LocalModelKind? {
        switch self {
        case .openAI: return nil
        case .local: return .speech
        case .paraformer: return .streamingSpeech
        }
    }
    var isLocal: Bool { localModel != nil }
    var sampleRate: Double { isLocal ? 16000 : 24000 }
}

enum EmbeddingService: String, Codable, CaseIterable, Identifiable {
    case openAI, local
    var id: String { rawValue }
    var label: String { self == .local ? "Local · BGE-M3" : "OpenAI Embeddings" }
}

enum LocalModelKind: String, CaseIterable, Identifiable, Sendable {
    case speech, streamingSpeech, embedding
    var id: String { rawValue }
    var title: String {
        switch self {
        case .speech: return "SenseVoiceSmall + Silero VAD"
        case .streamingSpeech: return "Paraformer-zh-streaming + Silero VAD"
        case .embedding: return "BGE-M3 · Q8"
        }
    }
    var directory: String {
        switch self {
        case .speech: return "sensevoice-int8-v1"
        case .streamingSpeech: return "paraformer-streaming-zh-en-int8-v1"
        case .embedding: return "bge-m3-q8-v1"
        }
    }
    var downloadSize: String {
        switch self {
        case .speech: return "164 MB"
        case .streamingSpeech: return "238 MB"
        case .embedding: return "635 MB"
        }
    }
    var downloads: [ModelDownload] {
        switch self {
        case .speech: return [.senseVoice, .vad]
        case .streamingSpeech: return [.paraformerEncoder, .paraformerDecoder, .paraformerTokens, .vad]
        case .embedding: return [.bge]
        }
    }
    static let embeddingIdentity = "local:bge-m3:q8_0:950f4a8e5e19:cls:l2:v1"
    var files: [String] {
        switch self {
        case .speech: return ["model.int8.onnx", "tokens.txt", "silero_vad.onnx"]
        case .streamingSpeech: return ["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt", "silero_vad.onnx"]
        case .embedding: return ["bge-m3-Q8_0.gguf"]
        }
    }
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
    var installedName: String? = nil
    private static let paraformerBase = "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en/resolve/8e40c43232a1c5c66c82111efc5820d3accca11b/"
    static let paraformerEncoder = Self(
        url: URL(string: paraformerBase + "encoder.int8.onnx")!,
        sha256: "81a70226a8934e6ed92aa1d4fc486b428b5398e2f2619ed4897b7294cab90e9a",
        name: "paraformer-encoder.int8.onnx", installedName: "encoder.int8.onnx")
    static let paraformerDecoder = Self(
        url: URL(string: paraformerBase + "decoder.int8.onnx")!,
        sha256: "f3cca9f77bb9d93c8fcbfb63ae617b6b1ee96818df3aa3b151c40658fe38594f",
        name: "paraformer-decoder.int8.onnx", installedName: "decoder.int8.onnx")
    static let paraformerTokens = Self(
        url: URL(string: paraformerBase + "tokens.txt")!,
        sha256: "59aba8873a2ed1e122c25fee421e25f283b63290efbde85c1f01a853d83cb6e6",
        name: "paraformer-tokens.txt", installedName: "tokens.txt")
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

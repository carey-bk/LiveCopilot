import Foundation
import CryptoKit

enum ListeningService: String, Codable, CaseIterable, Identifiable {
    case zipformer, paraformer, apple, openAI
    var id: String { rawValue }
    var label: String {
        switch self {
        case .openAI: return "OpenAI · GPT-Live"
        case .apple: return "Apple · on-device speech"
        case .paraformer: return "Local · Paraformer-zh-streaming"
        case .zipformer: return "Local · Zipformer · terminology"
        }
    }
    var localModel: LocalModelKind? {
        switch self {
        case .openAI, .apple: return nil
        case .paraformer: return .streamingSpeech
        case .zipformer: return .terminologySpeech
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Preserve all other preferences when upgrading the retired sentence recognizer.
        if value == "local" { self = .zipformer; return }
        guard let service = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown listening service")
        }
        self = service
    }
    var isLocal: Bool { self != .openAI }
    var sampleRate: Double { isLocal ? 16000 : 24000 }
}

enum EmbeddingService: String, Codable, CaseIterable, Identifiable {
    case openAI, local
    var id: String { rawValue }
    var label: String { self == .local ? "Local · \(LocalModelKind.embeddingName)" : "OpenAI Embeddings" }
}

enum LocalModelKind: String, CaseIterable, Identifiable, Sendable {
    case streamingSpeech, embedding, terminologySpeech
    var id: String { rawValue }
    var isBundled: Bool {
        #if MAS_OFFLINE
        return self == .embedding || self == .terminologySpeech
        #else
        return self == .embedding
        #endif
    }
    var title: String {
        switch self {
        case .streamingSpeech: return "Paraformer-zh-streaming + Silero VAD"
        case .terminologySpeech: return "Zipformer + Silero VAD"
        case .embedding: return "Arctic · INT8"
        }
    }
    var directory: String {
        switch self {
        case .streamingSpeech: return "paraformer-streaming-zh-en-int8-v1"
        case .terminologySpeech: return "zipformer-streaming-zh-en-hotwords-v1"
        case .embedding: return "arctic-m-v2-int8"
        }
    }
    var downloadSize: String {
        switch self {
        case .streamingSpeech: return "238 MB"
        case .terminologySpeech: return "200 MB"
        case .embedding: return "328 MB · bundled"
        }
    }
    /// Known object sizes from the pinned distribution manifest. Estimates only;
    /// download progress always uses actual URLSession transfer measurements.
    var estimatedDownloadBytes: Int64 {
        switch self {
        case .streamingSpeech: return 165_462_184 + 71_664_561 + 75_756 + 643_854
        case .embedding: return 0
        case .terminologySpeech: return 181_895_032 + 13_876_452 + 3_228_404 + 56_317 + 12_564 + 643_854
        }
    }
    var downloads: [ModelDownload] {
        switch self {
        case .streamingSpeech: return [.paraformerEncoder, .paraformerDecoder, .paraformerTokens, .vad]
        case .embedding: return []
        case .terminologySpeech: return [.zipEncoder, .zipDecoder, .zipJoiner, .zipTokens, .zipBPE, .vad]
        }
    }
        static let embeddingIdentity = "local:arctic-m-v2:int8:03d923bb1850:tok-f1cc44ad7faa:cls:l2:768:v1"
    static let embeddingDimensions = 768
    static let retrievalFloor = 0.32
    static let embeddingName = "Arctic"
    var files: [String] {
        switch self {
        case .streamingSpeech: return ["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt", "silero_vad.onnx"]
        case .embedding: return ["ms-model_int8.onnx", "tokenizer.json"]
        case .terminologySpeech: return ["encoder.int8.onnx", "decoder.onnx", "joiner.int8.onnx", "tokens.txt", "bpe.vocab", "silero_vad.onnx"]
        }
    }
    func location(in root: URL) -> URL {
        if isBundled { return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/OfflineModels/" + directory) }
        return root.appendingPathComponent(directory, isDirectory: true)
    }
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
    var ossObjectKey: String? = nil
    var availableOnDistribution = true
    /// Pinned extra sources for this file, tried after the configured distribution and before generic host mirrors.
    /// Used when a mirror serves the identical object under a different host and path.
    var mirrors: [URL] = []
    var ossKey: String { ossObjectKey ?? "local/" + name }
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
    static let vad = Self(
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")!,
        sha256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6", name: "silero_vad.onnx")
    // Matching immutable revisions on ModelScope and Hugging Face. Same hashes on every route.
    private static let zipHF = "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/98590b7ed6443e77b714204da2757d75e1a642f4/"
    private static let zipMS = "https://modelscope.cn/models/pkufool/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/fe4123ca09cd7efaef00fe0ed88219211bc5b77e/"
    private static func zip(_ file: String, installed: String, hash: String, modelScope: Bool = true) -> Self {
        Self(url: URL(string: zipHF + file)!, sha256: hash, name: "zipformer-" + file,
             installedName: installed, availableOnDistribution: false,
             mirrors: modelScope ? [URL(string: zipMS + file)!, URL(string: zipHF + file)!] : [])
    }
    static let zipEncoder = zip("encoder-epoch-99-avg-1.int8.onnx", installed: "encoder.int8.onnx", hash: "8fa764187a261844f859d7143ebaa563af5d10adfece4c18a8f414c88cba2a9b")
    // Keep decoder FP32, as recommended by the model's official int8 example.
    static let zipDecoder = zip("decoder-epoch-99-avg-1.onnx", installed: "decoder.onnx", hash: "2e3b5ec371f8899ee6acd829fd753ba45772df57a91bdf37cde3136354e7db7d")
    static let zipJoiner = zip("joiner-epoch-99-avg-1.int8.onnx", installed: "joiner.int8.onnx", hash: "1ed689c5ed19dbaa725d9d191bb4822b5f4855a39e1ffd28cbc1f340d25b2ee0")
    static let zipTokens = zip("tokens.txt", installed: "tokens.txt", hash: "a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3")
    // Tiny vocabulary is also bundled, so mainland installs need no overseas request for it.
    static let zipBPE = zip("bpe.vocab", installed: "bpe.vocab", hash: "d0b642f3a2eacd5fadefdeff9e0e1358cab729647cbb7fe58cf738e1f7407029", modelScope: false)
    /// Exact object lengths in docs/oss-model-manifest.json, keyed by the pinned SHA-256.
    /// A new payload without a matching manifest entry deliberately has unknown size.
    var knownByteCount: Int64? {
        let zipSizes: [String: Int64] = [Self.zipEncoder.sha256: 181_895_032, Self.zipDecoder.sha256: 13_876_452,
            Self.zipJoiner.sha256: 3_228_404, Self.zipTokens.sha256: 56_317, Self.zipBPE.sha256: 12_564]
        if let size = zipSizes[sha256] { return size }
        switch sha256 {
        case "81a70226a8934e6ed92aa1d4fc486b428b5398e2f2619ed4897b7294cab90e9a": return 165_462_184
        case "f3cca9f77bb9d93c8fcbfb63ae617b6b1ee96818df3aa3b151c40658fe38594f": return 71_664_561
        case "59aba8873a2ed1e122c25fee421e25f283b63290efbde85c1f01a853d83cb6e6": return 75_756
        case "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6": return 643_854
        default: return nil
        }
    }
    func verify(_ file: URL) throws { try Self.verify(file, sha256: sha256) }
    static func verify(_ file: URL, sha256: String) throws {
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

/// Public, read-only HTTPS origin. No distribution credentials are stored in the app.
enum ModelDistribution {
    /// Public, immutable ModelScope snapshot used by release builds without a local config file.
    /// A user-specific HTTPS source can override it; no credentials are embedded in the app.
    private static let defaultBaseURL = URL(string: "https://modelscope.cn/models/careybk/livecopilot-model-assets/resolve/a5ba0b9be08e7d8f7438e3762791ac5b62c1e253")!
    static var baseURL: URL? {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let variant = Bundle.main.bundleIdentifier == "com.livecopilot.development" ? "Development" : ""
        let file = root.appendingPathComponent("LiveCopilot").appendingPathComponent(variant)
            .appendingPathComponent("model-distribution.json")
        guard let data = try? Data(contentsOf: file),
              let config = try? JSONDecoder().decode(Configuration.self, from: data),
              let address = config.modelScopeBaseURL ?? config.ossBaseURL,
              let url = URL(string: address), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return defaultBaseURL }
        return url
    }
    private struct Configuration: Decodable {
        let modelScopeBaseURL: String?
        let ossBaseURL: String?
    }
}

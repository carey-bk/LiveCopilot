import Foundation
import Darwin

enum LayaBackend: String {
    case fp16, e8, w8, e8w16, e4w8, w4
}

struct LayaNativeAssets: Decodable, Equatable {
    let schema: Int
    let weight_bytes: Int64
    let backend, precision, source_sha256: String
    let files: [String: String]

    static func pins(_ resources: URL, _ mode: LayaBackend) throws -> Self {
        let url = resources.appendingPathComponent("native-" + mode.rawValue + ".json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    static func bundledMode(_ resources: URL) -> LayaBackend {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("native-coreml.json")),
              let pin = try? JSONDecoder().decode(Self.self, from: data),
              pin.schema == 2, pin.backend == "coreml",
              let mode = LayaBackend(rawValue: pin.precision),
              (try? pins(resources, mode)) == pin else { return .fp16 }
        return mode
    }

    func installed(at directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("receipt.json")),
              (try? JSONDecoder().decode(Self.self, from: data)) == self else { return false }
        return files.keys.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    private struct Original: Decodable {
        struct File: Decodable { let name, sha256: String; let url: URL; let size: Int64 }
        let model: [File]
    }

    static func downloadSize(resources: URL, mode: LayaBackend) -> Int64? {
        guard let pins = try? pins(resources, mode),
              let data = try? Data(contentsOf: resources.appendingPathComponent("pins.json")),
              let model = try? JSONDecoder().decode(Original.self, from: data).model else { return nil }
        return model.filter { pins.files[$0.name] != nil }.reduce(0) { sum, asset in
            if mode == .e8 && asset.name == "model.safetensors" { return sum + pins.weight_bytes }
            return sum + asset.size
        }
    }

    // The original pinned tokenizer already contains the exact vocabulary. Strip
    // JSON whitespace outside strings to reproduce the offline export byte for byte.
    private static func compactTokenizer(_ file: URL) throws {
        let input = try Data(contentsOf: file)
        var result = Data(), inString = false, escaped = false
        for byte in input {
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 { inString = true }
            else if byte == 32 || byte == 9 || byte == 10 || byte == 13 { continue }
            result.append(byte)
        }
        try result.write(to: file, options: .atomic)
    }

    static func stage(_ mode: LayaBackend, resources: URL, source: URL?, to directory: URL,
                      progress: @escaping @Sendable (Double?, String) -> Void,
                      file: @escaping @Sendable (Int, Int) -> Void) async throws {
        let pins = try pins(resources, mode)
        let fm = FileManager.default
        let original = try JSONDecoder().decode(Original.self, from: Data(contentsOf: resources.appendingPathComponent("pins.json")))
        for (index, name) in pins.files.keys.sorted().enumerated() {
            try Task.checkCancellation()
            file(index + 1, pins.files.count)
            let target = directory.appendingPathComponent(name)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let source {
                try fm.copyItem(at: source.appendingPathComponent(mode.rawValue).appendingPathComponent(name), to: target)
            } else if name == "model.safetensors" && mode == .e8 {
                guard let base = ModelDistribution.baseURL else { throw LayaRuntimeError.installationFailed }
                let key = "laya/native/" + pins.source_sha256 + "/e8/" + name
                try await LocalModelInstaller.download(ModelDownload(url: base.appendingPathComponent(key),
                    sha256: pins.files[name]!, name: name, ossObjectKey: key), to: target, progress: progress)
            } else {
                guard let asset = original.model.first(where: { $0.name == name }) else { throw LayaRuntimeError.installationFailed }
                try await LocalModelInstaller.download(ModelDownload(url: asset.url, sha256: asset.sha256,
                    name: name, availableOnDistribution: false), to: target, progress: progress)
                if name == "tokenizer/tokenizer.json" { try compactTokenizer(target) }
            }
        }
        try fm.copyItem(at: resources.appendingPathComponent("native-" + mode.rawValue + ".json"),
                        to: directory.appendingPathComponent("receipt.json"))
    }

    static func publish(_ stage: URL, to current: URL) throws {
        if FileManager.default.fileExists(atPath: current.path) {
            guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, current.path, UInt32(RENAME_SWAP)) == 0
            else { throw LayaRuntimeError.installationFailed }
        } else { try FileManager.default.moveItem(at: stage, to: current) }
    }
}

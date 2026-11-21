import Foundation

@main struct ModelHealthMain {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let executable = URL(fileURLWithPath: CommandLine.arguments[2])
        let provider = LocalEmbeddingProvider(directory: directory, executable: executable)
        defer { provider.close() }
        try await provider.prepare()
        let vectors = try await provider.embed(["Which document describes the design review?"])
        guard vectors.count == 1, vectors[0].count == LocalModelKind.embeddingDimensions else {
            throw CopilotError.message("Invalid Arctic embedding")
        }
        print("PASS bundled Arctic CPU query, 768 dimensions")
    }
}

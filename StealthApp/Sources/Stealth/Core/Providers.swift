import Foundation

protocol EmbeddingProvider {
    var model: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}
protocol ReasoningProvider {
    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error>
}

enum LiveEvent {
    case ready
    case transcript(TranscriptFragment)
    /// A replacement preview for one speaker; not persisted or used for analysis.
    case partialTranscript(String)
    case delegation(id: String, offsetMS: Int)
    case speechActivity(Bool)
    case status(String)
    case failed(String)
    case closed(finalized: Bool)
}

@MainActor protocol LiveProvider: AnyObject {
    var onEvent: ((LiveEvent) -> Void)? { get set }
    func connect(context: String)
    func sendAudio(_ data: Data)
    func appendContext(_ text: String, delegationID: String?)
    func disconnect() async
}

struct MockEmbeddingProvider: EmbeddingProvider {
    let model = "mock-embedding-v1"
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: 64)
            for token in LexicalTokenizer.terms(text) {
                var hash: UInt64 = 1469598103934665603
                for byte in token.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
                vector[Int(hash % 64)] += 1
            }
            return vector
        }
    }
}

struct MockReasoningProvider: ReasoningProvider {
    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let evidence = request.sources.isEmpty ? "No local evidence retrieved." : "\(request.sources[0].chunk.text.prefix(300)) [S1]"
            let text = "## Core answer\nMock preview — \(request.query.question)\n\n## Evidence\n\(evidence)\n\n## General context\nThis is deterministic demo output; no OpenAI request was made.\n"
            let task = Task {
                for part in text.components(separatedBy: " ") {
                    if Task.isCancelled { break }
                    continuation.yield(part + " ")
                    try? await Task.sleep(nanoseconds: 12_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

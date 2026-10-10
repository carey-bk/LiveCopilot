import Foundation

/// Monotonic stage markers. No text, document metadata, audio or credentials.
struct PipelineTrace: Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        case asrStable = "asr_stable", questionEnd = "question_end"
        case jevStart = "jev_start", jevEnd = "jev_end", analysisDispatched = "analysis_dispatched"
        case embeddingStart = "embedding_start", embeddingComplete = "embedding_complete"
        case ragComplete = "rag_complete", modelRequest = "model_request"
        case firstServiceEvent = "first_service_event", reasoningStarted = "reasoning_started"
        case firstToken = "first_token", answerComplete = "answer_complete", cancelled, failed
    }
    let id: UUID
    let origin: TimeInterval
    private(set) var times: [Stage: TimeInterval] = [:]
    init(id: UUID = UUID(), origin: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.id = id; self.origin = origin
    }
    mutating func mark(_ stage: Stage, at: TimeInterval = ProcessInfo.processInfo.systemUptime) { times[stage] = at }
    func milliseconds(_ stage: Stage) -> Int? { times[stage].map { Int(($0 - origin) * 1000) } }
    func logLine(_ stage: Stage) -> String {
        "pipeline trace=\(id.uuidString) stage=\(stage.rawValue) elapsed_ms=\(milliseconds(stage) ?? -1) uptime_ms=\(Int((times[stage] ?? origin) * 1000))"
    }
}

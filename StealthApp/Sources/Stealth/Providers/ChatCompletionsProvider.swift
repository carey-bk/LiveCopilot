import Foundation

/// DeepSeek and services implementing the OpenAI Chat Completions wire format.
/// Deliberately displays final content only, never reasoning_content.
struct ChatCompletionsProvider: ReasoningProvider {
    let key: String
    let model: String
    let endpoint: URL
    var deepSeekEffort: String? = nil
    var transport: any HTTPTransport = URLSessionTransport()

    func httpRequest(_ answer: AnswerRequest) throws -> URLRequest {
        guard !key.isEmpty else { throw CopilotError.message("Configure the analysis service API key in Services.") }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CopilotError.message("Enter an analysis model name in Services.") }
        var body: [String: Any] = ["model": model, "stream": true, "max_tokens": 4096,
            "messages": [["role": "system", "content": answer.instructions], ["role": "user", "content": answer.input]]]
        if let effort = deepSeekEffort {
            body["thinking"] = ["type": effort == "none" ? "disabled" : "enabled"]
            if !effort.isEmpty && effort != "none" { body["reasoning_effort"] = effort }
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let http = try httpRequest(request)
                    var parser = ServerSentEvents(), completed = false, hadText = false
                    func handle(_ payload: String) throws {
                        if payload == "[DONE]" { completed = true; return }
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            throw CopilotError.message("Malformed reasoning stream. Retry this question.")
                        }
                        guard object["error"] == nil else {
                            throw CopilotError.message("Analysis service failed. Check its model, key and API limits.")
                        }
                        guard let choices = object["choices"] as? [[String: Any]] else {
                            throw CopilotError.message("Malformed reasoning stream. Retry this question.")
                        }
                        for choice in choices where (choice["index"] as? Int ?? 0) == 0 {
                            if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String, !content.isEmpty {
                                hadText = true; continuation.yield(content)
                            }
                            if let reason = choice["finish_reason"] as? String {
                                guard reason == "stop" else {
                                    throw CopilotError.message("The analysis answer was interrupted or exceeded its limit. Partial text is retained; retry.")
                                }
                                completed = true
                            }
                        }
                    }
                    for try await line in transport.lines(for: http) {
                        try Task.checkCancellation()
                        if let event = parser.consume(line) { try handle(event) }
                        if completed { break }
                    }
                    if let event = parser.finish() { try handle(event) }
                    guard completed && hadText else { throw CopilotError.message("Reasoning stream ended without a complete answer. Check the network and retry.") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum ReasoningProviderFactory {
    static func make(settings: AppSettings, liveKey: String?, analysisKey: String?, transport: any HTTPTransport = URLSessionTransport()) throws -> any ReasoningProvider {
        // A non-OpenAI service must never inherit the Live key.
        let key = settings.reasoningService == .sharedOpenAI ? liveKey : analysisKey
        guard let key, !key.isEmpty else { throw CopilotError.message("Configure the analysis service API key in Services.") }
        switch settings.reasoningService {
        case .sharedOpenAI, .separateOpenAI:
            return OpenAIReasoningProvider(key: key, model: settings.reasoningModel, effort: settings.reasoningEffort, transport: transport)
        case .deepSeek:
            return ChatCompletionsProvider(key: key, model: settings.deepSeekModel, endpoint: URL(string: "https://api.deepseek.com/chat/completions")!, deepSeekEffort: settings.deepSeekEffort, transport: transport)
        case .compatible:
            return ChatCompletionsProvider(key: key, model: settings.compatibleModel, endpoint: try settings.compatibleEndpoint(), transport: transport)
        }
    }
}

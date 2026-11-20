import Foundation

/// DeepSeek, Qwen, GLM, Kimi and services implementing the OpenAI Chat Completions wire format.
/// Deliberately displays final content only, never reasoning_content.
struct ChatCompletionsProvider: ReasoningProvider {
    let key: String
    let model: String
    let endpoint: URL
    var service = ReasoningService.compatible
    var thinking = AnalysisThinking.modelDefault
    var deepSeekEffort: String? = nil
    var transport: any HTTPTransport = URLSessionTransport()

    func httpRequest(_ answer: AnswerRequest) throws -> URLRequest {
        guard !key.isEmpty else { throw CopilotError.message("Configure the analysis service API key in Services.") }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CopilotError.message("Enter an analysis model name in Services.") }
        var body: [String: Any] = ["model": model, "stream": true, "max_tokens": answer.sessionTitleInput == nil ? 4096 : 512,
            "messages": [["role": "system", "content": answer.instructions], ["role": "user", "content": answer.input]]]
        if let requested = deepSeekEffort {
            let mode = AnalysisModelCatalog.normalized(requested, model: model, service: .deepSeek)
            if mode != .modelDefault {
                body["thinking"] = ["type": mode == .disabled ? "disabled" : "enabled"]
                if let effort = mode.effort { body["reasoning_effort"] = effort }
            }
        }
        // Do not send another vendor's optional fields or fixed sampling parameters.
        let thinking = service.normalizedThinking(thinking, model: model)
        if thinking != .modelDefault {
            switch service {
            case .qwen: body["enable_thinking"] = thinking != .disabled
            case .glm: body["thinking"] = ["type": thinking != .disabled ? "enabled" : "disabled"]
            case .kimi:
                // K3 uses effort only; its API does not accept the K2.x thinking toggle.
                if model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "kimi-k3" {
                    body["thinking"] = ["type": thinking != .disabled ? "enabled" : "disabled"]
                }
            default: break
            }
            if service.isPreset, let effort = thinking.effort { body["reasoning_effort"] = effort }
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
                    var reportedService = false, reportedReasoning = false
                    func handle(_ payload: String) async throws {
                        if payload == "[DONE]" { completed = true; return }
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            throw CopilotError.message("Malformed reasoning stream. Retry this question.")
                        }
                        if let errorValue = object["error"], !(errorValue is NSNull) {
                            throw ServiceHTTPFailure(status: 0, data: data)
                        }
                        guard let choices = object["choices"] as? [[String: Any]] else {
                            throw CopilotError.message("Malformed reasoning stream. Retry this question.")
                        }
                        if !reportedService {
                            reportedService = true
                            await request.onStreamProgress?(.firstServiceEvent, ProcessInfo.processInfo.systemUptime)
                        }
                        for choice in choices where (choice["index"] as? Int ?? 0) == 0 {
                            if !reportedReasoning, let delta = choice["delta"] as? [String: Any],
                               let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                                reportedReasoning = true
                                await request.onStreamProgress?(.reasoningStarted, ProcessInfo.processInfo.systemUptime)
                            }
                            if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String, !content.isEmpty {
                                hadText = true; continuation.yield(content)
                            }
                            if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                                guard reason == "stop" else {
                                    throw CopilotError.message("The analysis answer was interrupted or exceeded its limit. Partial text is retained; retry.")
                                }
                                completed = true
                            }
                        }
                    }
                    for try await line in transport.lines(for: http) {
                        try Task.checkCancellation()
                        if let event = parser.consume(line) { try await handle(event) }
                        if completed { break }
                    }
                    if let event = parser.finish() { try await handle(event) }
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
            return OpenAIReasoningProvider(key: key, model: settings.reasoningModel, effort: settings.reasoningEffort, processing: settings.analysisProcessing, transport: transport)
        case .deepSeek:
            return ChatCompletionsProvider(key: key, model: settings.deepSeekModel, endpoint: URL(string: "https://api.deepseek.com/chat/completions")!, deepSeekEffort: settings.deepSeekEffort, transport: transport)
        case .qwen, .glm, .kimi:
            let connection = settings.presetConnection!
            return ChatCompletionsProvider(key: key, model: connection.model, endpoint: try connection.endpoint(),
                                           service: settings.reasoningService, thinking: connection.thinking, transport: transport)
        case .compatible:
            return ChatCompletionsProvider(key: key, model: settings.compatibleModel, endpoint: try settings.compatibleEndpoint(), transport: transport)
        }
    }
}

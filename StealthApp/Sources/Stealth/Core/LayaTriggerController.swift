import Foundation

/// Fixed diagnostic vocabulary: no transcript, prompt, credential or arbitrary error strings.
enum LayaGateEvent: String, CaseIterable, Sendable {
    case ownSpeechStarted, ownSpeechEnded, otherSpeechStarted, otherSpeechEnded
    case inputReceived, received, predictionStarted, predictionCompleted, dispatched, discarded
    case disabled, loading, unavailable, captureInactive, ownSpeech, ownTranscript
    case emptyInput, shortPreview, noCandidate, duplicate, expired, predicting
    case waitingFinal, waitingSilence, belowThreshold, cooldown, busy, failed, idle, staleCandidate

    func label(_ language: AppLanguage) -> String {
        let pair: (String, String)
        switch self {
        case .ownSpeechStarted, .ownSpeechEnded, .otherSpeechStarted, .otherSpeechEnded, .inputReceived, .received, .idle: pair = ("Waiting for transcript", "等待转写输入")
        case .predictionStarted, .predicting: pair = ("Evaluating", "正在判断")
        case .predictionCompleted: pair = ("Decision received", "已收到判断")
        case .dispatched: pair = ("Answer queued", "已提交回答")
        case .discarded: pair = ("Outdated decision discarded", "已丢弃过期判断")
        case .disabled: pair = ("Automatic suggestions off", "自动建议未启用")
        case .loading: pair = ("Loading model", "正在加载模型")
        case .unavailable: pair = ("Model unavailable — check settings", "模型不可用，请检查设置")
        case .captureInactive: pair = ("Audio source inactive", "音轨未启动")
        case .ownSpeech: pair = ("Your microphone is active", "检测到我方语音，暂停自动回答")
        case .ownTranscript: pair = ("Your transcript interrupted the question", "我方转写中断了待回答问题")
        case .emptyInput: pair = ("Empty transcript", "转写内容为空")
        case .shortPreview: pair = ("Waiting for more transcript", "临时转写过短，等待后续")
        case .noCandidate: pair = ("No eligible question in context", "当前上下文没有可提交的问题")
        case .duplicate: pair = ("Question already handled", "该问题已处理，跳过重复")
        case .expired: pair = ("Question expired", "待回答问题已过期")
        case .waitingFinal: pair = ("Waiting for final transcript", "等待转写定稿")
        case .waitingSilence: pair = ("Waiting for speech to finish", "等待语音结束")
        case .belowThreshold: pair = ("Score below threshold", "评分低于阈值")
        case .cooldown: pair = ("Waiting for pause / cooldown", "等待停顿或冷却")
        case .busy: pair = ("Answer pipeline busy", "回答通道忙，等待重试")
        case .failed: pair = ("Prediction failed — check settings", "判断失败，请检查设置")
        case .staleCandidate: pair = ("Question context changed", "问题上下文已变化，取消提交")
        }
        return ServiceGuide.text(pair.0, pair.1, language)
    }
}

/// In-memory, current-listening-session diagnostics, safe to include in the public summary.
/// Survives stopping listening so users can export afterward; a new session resets counts.
enum LayaGateDiagnostics {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]
    private static var last = "idle"
    private static var started: Date?
    private static var recent: [String] = []
    static func begin() {
        lock.lock(); defer { lock.unlock() }
        counts = [:]; last = "idle"; started = Date(); recent = []
    }
    static func record(_ event: LayaGateEvent) {
        lock.lock(); defer { lock.unlock() }
        counts[event.rawValue, default: 0] += 1; last = event.rawValue
        recent.append("\(ISO8601DateFormatter().string(from: Date())) \(event.rawValue)")
        recent = Array(recent.suffix(32))
    }
    static func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        guard let started else { return "No listening session in this process. Counters are not persisted across restarts." }
        return "Session started: \(ISO8601DateFormatter().string(from: started))\nLast event: \(last)\n" +
            LayaGateEvent.allCases.map { "\($0.rawValue): \(counts[$0.rawValue, default: 0])" }.joined(separator: "\n") +
            "\nRecent events (maximum 32):\n" + recent.joined(separator: "\n") +
            "\nCounts are events/state transitions, not unique questions; no transcript content is collected."
    }
}

/// Semantic eligibility comes only from Laya. Text rules do not override its score.
/// Final ASR, silence, cooldown, speaker and lifecycle guards remain in the controller.
enum LayaTriggerDecision: String, Sendable {
    case belowThreshold, threshold
    var shouldTrigger: Bool { self == .threshold }
    static func evaluate(score: Double, threshold: Double) -> Self {
        guard score.isFinite, (0...1).contains(score), threshold.isFinite else { return .belowThreshold }
        return score >= threshold ? .threshold : .belowThreshold
    }
}

struct LayaDiagnosticResult: Sendable {
    let score: Double
    let threshold: Double
    let decision: LayaTriggerDecision
    /// Preparation and local prediction/IPC are measured separately. Neither is full trigger latency.
    let preparationMS: Double
    let predictionMS: Double
}

struct LayaTriggerInput: Equatable, Sendable {
    let text: String
    let context: String
    let speaker: Speaker
    let isFinal: Bool
    var trace: PipelineTrace? = nil
    var answerContext: String? = nil
    var sourceID: String? = nil
}

/// Scores revisions as they arrive, but only dispatches a committed, quiet turn.
/// Transcript content and deduplication keys stay in memory and are never logged.
@MainActor final class LayaTriggerController {
    struct Timing {
        let throttle: TimeInterval
        let quiet: TimeInterval
        let expiry: TimeInterval

        init(throttle: TimeInterval = 0.35, quiet: TimeInterval = 0.5, expiry: TimeInterval = 25) {
            self.throttle = Self.valid(throttle, fallback: 0.35)
            self.quiet = Self.valid(quiet, fallback: 0.5)
            self.expiry = Self.valid(expiry, fallback: 25)
        }

        fileprivate static func valid(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
            value.isFinite ? min(86_400, max(0, value)) : fallback
        }
    }

    var onError: ((String) -> Void)?
    var onDecision: ((Double) -> Void)?
    var onEvent: ((LayaGateEvent) -> Void)?
    private var lastWait: LayaGateEvent?
    private func wait(_ event: LayaGateEvent) {
        guard lastWait != event else { return }; lastWait = event; onEvent?(event)
    }
    var onTrace: ((PipelineTrace, PipelineTrace.Stage) -> Void)?

    private struct Candidate {
        let id: UInt64
        let key: String
        var input: LayaTriggerInput
        var expiresAt: TimeInterval
        var finalAt: TimeInterval?
        var attempted = false
        var score: Double?
        var deferred = false
        var trace = PipelineTrace()
    }

    private struct Flight {
        let id: UInt64
        let generation: UInt64
        let key: String
    }

    private let predict: (String, String) async throws -> Double
    private let onTrigger: (LayaTriggerInput) -> Bool
    private let timing: Timing
    private var enabled = false
    private var threshold = 0.8
    private var cooldown: TimeInterval = 7
    private var generation: UInt64 = 0
    private var nextID: UInt64 = 0
    private var candidate: Candidate?
    private var flight: Flight?
    private var speaking = Set<Speaker>()
    private var lastActivityAt: TimeInterval = 0
    private var lastSpeechEndAt: TimeInterval?
    private var lastPredictionAt: TimeInterval?
    private var lastTriggerAt: TimeInterval?
    private var suppressedSources: [String: String] = [:]
    private var handled = Set<String>()
    private var handledOrder: [String] = []
    private var dispatching = false
    private var predictionTask: Task<Void, Never>?
    private var throttleTask: Task<Void, Never>?
    private var dispatchTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    /// Timing is injectable for regression checks; ordinary callers use the two closures.
    init(predict: @escaping (String, String) async throws -> Double,
         onTrigger: @escaping (LayaTriggerInput) -> Bool,
         timing: Timing = Timing()) {
        self.predict = predict
        self.onTrigger = onTrigger
        self.timing = timing
    }

    deinit {
        predictionTask?.cancel()
        throttleTask?.cancel()
        dispatchTask?.cancel()
        expiryTask?.cancel()
    }

    func configure(enabled: Bool, threshold: Double = 0.8, cooldown: TimeInterval = 7) {
        self.threshold = threshold.isFinite ? min(1, max(0, threshold)) : 0.8
        self.cooldown = Timing.valid(cooldown, fallback: 7)
        if self.enabled != enabled {
            invalidateCurrent(rememberCurrent: true)
            self.enabled = enabled
        }
        attemptDispatch()
    }

    func submit(_ input: LayaTriggerInput) {
        onEvent?(.received)
        lastWait = nil
        guard enabled else { wait(.disabled); return }
        let key = Self.key(for: input.text)
        guard !key.isEmpty else { wait(.emptyInput); return }
        if input.speaker == .you {
            // A transcript can arrive without a separate speech-start notification.
            invalidateCurrent(rememberCurrent: true)
            wait(.ownTranscript)
            return
        }
        // Preserve stale replay protection. Only a distinct committed ASR event can
        // distinguish a genuinely repeated question from the suppressed old delivery.
        guard !speaking.contains(.you) else {
            if input.isFinal, let sourceID = input.sourceID {
                suppressedSources[key] = sourceID
                if suppressedSources.count > 128, let oldest = suppressedSources.keys.first { suppressedSources.removeValue(forKey: oldest) }
            } else { remember(key) }
            wait(.ownSpeech); return
        }
        if let suppressed = suppressedSources[key] {
            guard input.isFinal, let sourceID = input.sourceID, sourceID != suppressed else { wait(.duplicate); return }
            suppressedSources.removeValue(forKey: key)
        }
        guard !handled.contains(key) else { wait(.duplicate); return }
        if expireIfNeeded(), handled.contains(key) { return }

        let now = Self.now
        if var current = candidate, current.key == key {
            if current.input.isFinal && !input.isFinal { return }
            // Reuse a score only for the same semantic input. A context revision
            // invalidates an in-flight result without renewing the candidate's lifetime.
            if current.input.context != input.context || current.input.speaker != input.speaker {
                nextID &+= 1
                candidate = Candidate(id: nextID, key: key, input: input,
                                      expiresAt: current.expiresAt,
                                      finalAt: current.finalAt ?? (input.isFinal ? now : nil),
                                      deferred: current.deferred, trace: current.trace)
                if input.isFinal && !current.input.isFinal {
                    candidate?.trace.mark(.asrStable, at: now)
                    if let trace = candidate?.trace { onTrace?(trace, .asrStable) }
                    lastActivityAt = now
                }
                dispatchTask?.cancel(); dispatchTask = nil
                scheduleExpiry()
                startPredictionIfNeeded()
                return
            }
            // Duplicate finals/punctuation cannot renew the quiet window or expiry.
            if current.input.isFinal { return }
            if current.input.speaker == input.speaker {
                guard input.isFinal else { return }
                current.input = input
                current.finalAt = now
                current.trace.mark(.asrStable, at: now)
                onTrace?(current.trace, .asrStable)
                current.expiresAt = now + timing.expiry
                candidate = current
                lastActivityAt = now
                scheduleExpiry()
                attemptDispatch()
                return
            }
        }

        // Once a committed turn is superseded, a delayed replay of that final
        // must not replace the newer candidate. Partial revisions may still retract.
        if let current = candidate, current.input.isFinal { remember(current.key) }
        nextID &+= 1
        candidate = Candidate(id: nextID, key: key, input: input,
                              expiresAt: now + timing.expiry, finalAt: input.isFinal ? now : nil,
                              trace: PipelineTrace(origin: min(now, lastSpeechEndAt ?? now)))
        if input.isFinal {
            candidate?.trace.mark(.asrStable, at: now)
            if let trace = candidate?.trace { onTrace?(trace, .asrStable) }
        }
        if let ended = lastSpeechEndAt, speaking.isEmpty {
            candidate?.trace.mark(.questionEnd, at: ended)
            if let trace = candidate?.trace { onTrace?(trace, .questionEnd) }
        }
        lastActivityAt = now
        dispatchTask?.cancel()
        dispatchTask = nil
        scheduleExpiry()
        startPredictionIfNeeded()
    }

    func setSpeaking(_ active: Bool, speaker: Speaker) {
        let changed: Bool
        if active { changed = speaking.insert(speaker).inserted }
        else { changed = speaking.remove(speaker) != nil }
        guard changed else { return }
        if active { lastSpeechEndAt = nil }
        if active, speaker == .you { invalidateCurrent(rememberCurrent: true); wait(.ownSpeech) }
        lastActivityAt = Self.now
        dispatchTask?.cancel()
        dispatchTask = nil
        if !active {
            lastSpeechEndAt = Self.now
            candidate?.trace.mark(.questionEnd)
            if let trace = candidate?.trace { onTrace?(trace, .questionEnd) }
            attemptDispatch()
        }
    }

    /// Ends the current lifecycle, including deduplication and cooldown history.
    /// Configuration is retained; a subsequent submit starts a fresh lifecycle.
    func reset() {
        invalidateCurrent(rememberCurrent: false)
        suppressedSources.removeAll()
        handled.removeAll()
        handledOrder.removeAll()
        speaking.removeAll()
        lastActivityAt = 0
        lastSpeechEndAt = nil
        lastPredictionAt = nil
        lastTriggerAt = nil
        lastWait = nil
    }

    /// Retires both the visible revision and any older prediction still completing.
    func manualIntervention() {
        invalidateCurrent(rememberCurrent: true)
    }

    /// Call when answer generation becomes available. A busy callback is never polled
    /// automatically and its cached score is reused until the candidate expires.
    func retryPending() {
        guard !expireIfNeeded() else { return }
        candidate?.deferred = false
        attemptDispatch()
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func key(for text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        var normalized = folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // Ignore sentence-ending punctuation, but preserve decimals, contractions,
        // and names such as C# so distinct follow-ups keep distinct identities.
        while let last = normalized.last, last.isWhitespace || ".!?。！？…".contains(last) {
            normalized.removeLast()
        }
        return normalized
    }

    private static func sleep(_ duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64((max(0, duration) * 1_000_000_000).rounded(.up)))
    }

    private func remember(_ key: String) {
        guard handled.insert(key).inserted else { return }
        handledOrder.append(key)
        if handledOrder.count > 128 { handled.remove(handledOrder.removeFirst()) }
    }

    private func invalidateCurrent(rememberCurrent: Bool) {
        if rememberCurrent {
            if let key = candidate?.key { remember(key) }
            if let key = flight?.key { remember(key) }
        }
        generation &+= 1
        candidate = nil
        // Retire its result without cancelling a healthy persistent worker on every
        // own-speech/manual event. Explicit runtime stop still terminates inference.
        // Keep the physical slot occupied until this bounded request settles.
        throttleTask?.cancel()
        throttleTask = nil
        dispatchTask?.cancel()
        dispatchTask = nil
        expiryTask?.cancel()
        expiryTask = nil
    }

    @discardableResult private func expireIfNeeded() -> Bool {
        guard let current = candidate, Self.now >= current.expiresAt else { return false }
        invalidateCurrent(rememberCurrent: true)
        wait(.expired)
        return true
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let current = candidate else { expiryTask = nil; return }
        let epoch = generation
        let delay = current.expiresAt - Self.now
        expiryTask = Task { [weak self] in
            do { try await Self.sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, self.generation == epoch,
                  self.candidate?.id == current.id else { return }
            self.expiryTask = nil
            if !self.expireIfNeeded() { self.scheduleExpiry() }
        }
    }

    private func startPredictionIfNeeded() {
        guard !expireIfNeeded(), enabled, !speaking.contains(.you),
              var current = candidate, !current.attempted, predictionTask == nil else { return }
        let interval = current.input.isFinal ? min(timing.throttle, 0.05) : timing.throttle
        let delay = (lastPredictionAt.map { $0 + interval } ?? Self.now) - Self.now
        if delay > 0 {
            // The first revision schedules a fixed throttle deadline. Later revisions
            // only replace the candidate; they do not push that deadline back.
            guard throttleTask == nil else { return }
            let epoch = generation
            throttleTask = Task { [weak self] in
                do { try await Self.sleep(delay) } catch { return }
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                self.throttleTask = nil
                self.startPredictionIfNeeded()
            }
            return
        }
        throttleTask?.cancel()
        throttleTask = nil
        onEvent?(.predictionStarted)
        wait(.predicting)
        current.attempted = true
        current.trace.mark(.jevStart)
        onTrace?(current.trace, .jevStart)
        candidate = current
        lastPredictionAt = Self.now
        let request = Flight(id: current.id, generation: generation, key: current.key)
        flight = request
        let predict = self.predict
        let input = current.input
        predictionTask = Task { [weak self] in
            guard !Task.isCancelled, self?.generation == request.generation else {
                self?.finishPrediction(request, result: .failure(CancellationError()), cancelled: true)
                return
            }
            let result: Result<Double, Error>
            do { result = .success(try await predict(input.text, input.context)) }
            catch { result = .failure(error) }
            self?.finishPrediction(request, result: result, cancelled: Task.isCancelled)
        }
    }

    private func finishPrediction(_ request: Flight, result: Result<Double, Error>, cancelled: Bool) {
        guard flight?.id == request.id else { return }
        flight = nil
        predictionTask = nil
        guard !cancelled, generation == request.generation, enabled,
              !speaking.contains(.you), !expireIfNeeded(), candidate?.id == request.id else {
            onEvent?(.discarded)
            startPredictionIfNeeded()
            return
        }
        switch result {
        case .success(let score) where score.isFinite && (0...1).contains(score):
            candidate?.score = score
            candidate?.trace.mark(.jevEnd)
            if let trace = candidate?.trace { onTrace?(trace, .jevEnd) }
            onEvent?(.predictionCompleted)
            onDecision?(score)
            attemptDispatch()
        case .success:
            wait(.failed)
            onError?("Laya returned an invalid confidence; automatic suggestion skipped.")
        case .failure:
            // Error descriptions from a worker may contain its input. Keep the
            // diagnostic generic, and never fall back to a punctuation heuristic.
            // Lifecycle cancellations were filtered above; an independently
            // cancelled worker is still a failure of this active prediction.
            wait(.failed)
            onError?("Laya prediction failed; automatic suggestion skipped.")
        }
        startPredictionIfNeeded()
    }

    private func attemptDispatch() {
        dispatchTask?.cancel()
        dispatchTask = nil
        guard !expireIfNeeded(), enabled, !dispatching, let current = candidate else { return }
        guard !speaking.contains(.you), current.input.speaker != .you else { wait(.ownSpeech); return }
        guard let score = current.score else { if current.attempted { wait(.predicting) }; return }
        guard LayaTriggerDecision.evaluate(score: score, threshold: threshold).shouldTrigger else { wait(.belowThreshold); return }
        guard current.input.isFinal, let finalAt = current.finalAt else { wait(.waitingFinal); return }
        guard speaking.isEmpty else { wait(.waitingSilence); return }
        guard !current.deferred else { wait(.busy); return }
        guard !handled.contains(current.key) else { wait(.duplicate); return }
        // A final ASR segment already includes endpoint silence. Requests with a
        // high response-needed score need only a short revision guard.
        let fast = score >= max(0.9, threshold)
        let quiet = fast ? min(timing.quiet, 0.15) : timing.quiet
        let interval = fast ? min(cooldown, 0.75) : cooldown
        let due = max(max(finalAt, lastActivityAt) + quiet,
                      lastTriggerAt.map { $0 + interval } ?? 0)
        let delay = due - Self.now
        if delay > 0 {
            wait(.cooldown)
            let epoch = generation
            dispatchTask = Task { [weak self] in
                do { try await Self.sleep(delay) } catch { return }
                guard !Task.isCancelled, let self, self.generation == epoch,
                      self.candidate?.id == current.id else { return }
                self.dispatchTask = nil
                self.attemptDispatch()
            }
            return
        }
        let epoch = generation
        dispatching = true
        var input = current.input
        input.trace = current.trace
        let accepted = onTrigger(input)
        dispatching = false
        guard generation == epoch else { return }
        if accepted {
            remember(current.key)
            lastTriggerAt = Self.now
            if candidate?.id == current.id {
                candidate = nil
                expiryTask?.cancel()
                expiryTask = nil
            }
            // A callback may synchronously submit a new turn; apply the cooldown.
            attemptDispatch()
        } else if candidate?.id == current.id {
            candidate?.deferred = true
            wait(.busy)
        }
    }
}

import Foundation

/// Local ASR often omits terminal punctuation. Restore only an explicit
/// question cue for Laya's classifier input; the transcript and answer query
/// retain the exact recognized words.
enum LayaPredictionText {
    static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !"?？!！.。".contains(trimmed.last!),
              !trimmed.hasPrefix("他") || !trimmed.contains("问我"),
              !trimmed.hasPrefix("她") || !trimmed.contains("问我"),
              LocalQuestionDetector.isQuestion(trimmed) else { return text }
        let chinese = trimmed.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        return trimmed + (chinese ? "？" : "?")
    }

    /// ASR may omit punctuation between two Chinese questions. Score the full
    /// utterance and a bounded first question with Laya; never shorten the text
    /// sent to the answer model. No rule alone can dispatch an answer here.
    static func variants(_ text: String) -> [String] {
        let full = normalized(text)
        guard LocalQuestionDetector.isQuestion(text) else { return [full] }
        var results = [full]
        for connector in ["它的", "他的", "她的", "它们的", "他们的"] {
            guard let range = text.range(of: connector),
                  text.distance(from: text.startIndex, to: range.lowerBound) >= 8 else { continue }
            let first = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard LocalQuestionDetector.isQuestion(first) else { continue }
            let variant = normalized(first)
            if variant != full { results.append(variant) }
            break
        }
        return results
    }
}

struct LayaTriggerInput: Equatable, Sendable {
    let text: String
    let context: String
    let speaker: Speaker
    let isFinal: Bool
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

    private struct Candidate {
        let id: UInt64
        let key: String
        var input: LayaTriggerInput
        var expiresAt: TimeInterval
        var finalAt: TimeInterval?
        var attempted = false
        var score: Double?
        var deferred = false
    }

    private struct Flight {
        let id: UInt64
        let generation: UInt64
        let key: String
    }

    private let predict: (String, String) async throws -> Double
    private let onTrigger: (LayaTriggerInput) -> Bool
    private let timing: Timing
    private let ruleNearMissMargin: Double
    private var enabled = false
    private var threshold = 0.8
    private var cooldown: TimeInterval = 7
    private var generation: UInt64 = 0
    private var nextID: UInt64 = 0
    private var candidate: Candidate?
    private var flight: Flight?
    private var speaking = Set<Speaker>()
    private var lastActivityAt: TimeInterval = 0
    private var lastPredictionAt: TimeInterval?
    private var lastTriggerAt: TimeInterval?
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
         timing: Timing = Timing(), ruleNearMissMargin: Double = 0) {
        self.predict = predict
        self.onTrigger = onTrigger
        self.timing = timing
        self.ruleNearMissMargin = max(0, min(0.2, ruleNearMissMargin))
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
        guard enabled else { return }
        let key = Self.key(for: input.text)
        guard !key.isEmpty else { return }
        if input.speaker == .you {
            // A transcript can arrive without a separate speech-start notification.
            invalidateCurrent(rememberCurrent: true)
            return
        }
        guard !speaking.contains(.you) else { remember(key); return }
        guard !handled.contains(key) else { return }
        if expireIfNeeded(), handled.contains(key) { return }

        let now = Self.now
        if var current = candidate, current.key == key {
            // Duplicate finals (including changed context or punctuation) cannot renew
            // the quiet window/expiry, downgrade a final, or repeat its prediction.
            if current.input.isFinal { return }
            if current.input.text == input.text, current.input.context == input.context,
               current.input.speaker == input.speaker {
                guard input.isFinal else { return }
                current.input = input
                current.finalAt = now
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
                              expiresAt: now + timing.expiry, finalAt: input.isFinal ? now : nil)
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
        if active, speaker == .you { invalidateCurrent(rememberCurrent: true) }
        lastActivityAt = Self.now
        dispatchTask?.cancel()
        dispatchTask = nil
        if !active { attemptDispatch() }
    }

    /// Ends the current lifecycle, including deduplication and cooldown history.
    /// Configuration is retained; a subsequent submit starts a fresh lifecycle.
    func reset() {
        invalidateCurrent(rememberCurrent: false)
        handled.removeAll()
        handledOrder.removeAll()
        speaking.removeAll()
        lastActivityAt = 0
        lastPredictionAt = nil
        lastTriggerAt = nil
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
        let delay = (lastPredictionAt.map { $0 + timing.throttle } ?? Self.now) - Self.now
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
        current.attempted = true
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
            startPredictionIfNeeded()
            return
        }
        switch result {
        case .success(let score) where score.isFinite && (0...1).contains(score):
            candidate?.score = score
            onDecision?(score)
            attemptDispatch()
        case .success:
            onError?("Laya returned an invalid confidence; automatic suggestion skipped.")
        case .failure:
            // Error descriptions from a worker may contain its input. Keep the
            // diagnostic generic, and never fall back to a punctuation heuristic.
            // Lifecycle cancellations were filtered above; an independently
            // cancelled worker is still a failure of this active prediction.
            onError?("Laya prediction failed; automatic suggestion skipped.")
        }
        startPredictionIfNeeded()
    }

    private func attemptDispatch() {
        dispatchTask?.cancel()
        dispatchTask = nil
        guard !expireIfNeeded(), enabled, !dispatching, speaking.isEmpty,
              let current = candidate, current.input.speaker != .you,
              current.input.isFinal, let finalAt = current.finalAt,
              let score = current.score,
              (score >= threshold ||
               (ruleNearMissMargin > 0 && score >= threshold - ruleNearMissMargin &&
                LocalQuestionDetector.isQuestion(current.input.text))),
              !current.deferred, !handled.contains(current.key) else { return }
        let due = max(max(finalAt, lastActivityAt) + timing.quiet,
                      lastTriggerAt.map { $0 + cooldown } ?? 0)
        let delay = due - Self.now
        if delay > 0 {
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
        let accepted = onTrigger(current.input)
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
        }
    }
}

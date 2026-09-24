import Foundation
#if XCODE_TESTS
@testable import LiveCopilot
#endif

@MainActor enum LayaTriggerChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Deliberately ignores cancellation while suspended, like an uncooperative
    /// worker. Tests choose exactly when each real controller await completes.
    @MainActor final class Predictor {
        struct Call { let text: String; let context: String; let at: TimeInterval }
        var calls: [Call] = []
        var automaticScore: Double?
        var active = 0
        var maximumActive = 0
        private var continuations: [Int: CheckedContinuation<Double, Error>] = [:]

        func predict(_ text: String, _ context: String) async throws -> Double {
            let index = calls.count
            calls.append(Call(text: text, context: context, at: ProcessInfo.processInfo.systemUptime))
            active += 1
            maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            if let automaticScore { return automaticScore }
            return try await withCheckedThrowingContinuation { continuations[index] = $0 }
        }

        func finish(_ index: Int, score: Double = 0.95) {
            continuations.removeValue(forKey: index)?.resume(returning: score)
        }

        func fail(_ index: Int) {
            continuations.removeValue(forKey: index)?.resume(throwing:
                NSError(domain: "LayaTest", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "private synthetic input must not escape"]))
        }

        func cancel(_ index: Int) {
            continuations.removeValue(forKey: index)?.resume(throwing: CancellationError())
        }

        func finishAll() {
            let pending = continuations.values
            continuations.removeAll()
            for continuation in pending { continuation.resume(returning: 0.95) }
        }
    }

    @MainActor final class Sink {
        var attempts: [LayaTriggerInput] = []
        var accepted: [LayaTriggerInput] = []
        var attemptTimes: [TimeInterval] = []
        var decisions: [Double] = []
        var errors: [String] = []
        var busy = false

        func receive(_ input: LayaTriggerInput) -> Bool {
            attempts.append(input)
            attemptTimes.append(ProcessInfo.processInfo.systemUptime)
            if !busy { accepted.append(input) }
            return !busy
        }
    }

    @MainActor final class Harness {
        let predictor: Predictor
        let sink: Sink
        let controller: LayaTriggerController

        init(score: Double? = nil, throttle: TimeInterval = 0.02,
             quiet: TimeInterval = 0.04, expiry: TimeInterval = 1,
             cooldown: TimeInterval = 0, threshold: Double = 0.8,
             ruleNearMissMargin: Double = 0) {
            let predictor = Predictor(), sink = Sink()
            predictor.automaticScore = score
            self.predictor = predictor
            self.sink = sink
            controller = LayaTriggerController(predict: { try await predictor.predict($0, $1) },
                                               onTrigger: { sink.receive($0) },
                                               timing: .init(throttle: throttle, quiet: quiet, expiry: expiry),
                                               ruleNearMissMargin: ruleNearMissMargin)
            controller.onDecision = { sink.decisions.append($0) }
            controller.onError = { sink.errors.append($0) }
            controller.configure(enabled: true, threshold: threshold, cooldown: cooldown)
        }

        func close() {
            controller.configure(enabled: false)
            controller.reset()
            predictor.finishAll()
        }
    }

    static func input(_ text: String, final: Bool = true, speaker: Speaker = .them,
                      context: String = "Synthetic conversation") -> LayaTriggerInput {
        .init(text: text, context: context, speaker: speaker, isFinal: final)
    }

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    static func pause(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func until(_ message: String, timeout: TimeInterval = 2,
                      _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            try expect(ProcessInfo.processInfo.systemUptime < deadline, "Timed out: " + message)
            try await pause(0.002)
        }
    }

    static func run() async throws -> [String] {
        var passed: [String] = []
        func check(_ name: String, _ body: () async throws -> Void) async throws {
            do { try await body(); passed.append(name) }
            catch { throw Failure(description: name + ": " + String(describing: error)) }
        }

        try await check("production timing and scenario cooldowns") {
            let timing = LayaTriggerController.Timing()
            try expect(timing.throttle == 0.35 && timing.quiet == 0.5 && timing.expiry == 25, "production timing changed")
            try expect(ScenarioProfile.interview.cooldown == 7 && ScenarioProfile.meeting.cooldown == 12, "scenario cooldown changed")
        }

        try await check("partial is scored but only a quiet final dispatches, reusing its score") {
            let h = Harness(); defer { h.close() }
            h.controller.submit(input("Please explain the tradeoffs", final: false))
            try await until("partial prediction") { h.predictor.calls.count == 1 }
            h.predictor.finish(0)
            try await until("partial decision") { h.sink.decisions.count == 1 }
            try await pause(0.08)
            try expect(h.sink.attempts.isEmpty, "unfinished partial dispatched")
            h.controller.submit(input("Please explain the tradeoffs"))
            try await pause(0.012)
            try expect(h.sink.attempts.isEmpty, "final skipped its quiet period")
            try await until("committed dispatch") { h.sink.attempts.count == 1 }
            try expect(h.sink.accepted.count == 1 && h.sink.accepted[0].isFinal, "dispatch was not a final")
            try expect(h.predictor.calls.count == 1, "identical final was unnecessarily predicted again")
        }

        try await check("continuous revisions are throttled without indefinite debounce") {
            let h = Harness(score: 0.95, throttle: 0.04); defer { h.close() }
            h.controller.submit(input("Explain revision zero", final: false))
            try await until("initial prediction") { h.predictor.calls.count == 1 }
            for index in 1...18 {
                h.controller.submit(input("Explain revision \(index)", final: false))
                try await pause(0.008)
                if index == 12 {
                    try expect(h.predictor.calls.count >= 2, "continuous revisions starved inference")
                }
            }
            try expect(h.sink.attempts.isEmpty, "a revision triggered before final")
            h.controller.submit(input("Explain revision 18"))
            try await until("latest final dispatch") { h.sink.attempts.count == 1 }
            try expect(h.sink.accepted[0].text == "Explain revision 18", "latest revision was lost")
            for pair in zip(h.predictor.calls, h.predictor.calls.dropFirst()) {
                try expect(pair.1.at - pair.0.at >= 0.038, "prediction exceeded its throttle")
            }
            try expect(h.predictor.maximumActive == 1, "predictions overlapped")
        }

        try await check("one in-flight prediction coalesces queued text and context to the latest") {
            let h = Harness(); defer { h.close() }
            h.controller.submit(input("Initial revision", final: false, context: "old context"))
            try await until("initial prediction") { h.predictor.calls.count == 1 }
            h.controller.submit(input("Intermediate revision", final: false))
            h.controller.submit(input("Latest complete request", context: "latest context"))
            try await pause(0.04)
            try expect(h.predictor.calls.count == 1, "second prediction started while busy")
            h.predictor.finish(0)
            try await until("coalesced prediction") { h.predictor.calls.count == 2 }
            try expect(h.predictor.calls[1].text == "Latest complete request" &&
                       h.predictor.calls[1].context == "latest context", "queued input was not latest-wins")
            try expect(h.sink.decisions.isEmpty && h.sink.attempts.isEmpty, "stale score escaped")
            h.predictor.finish(1)
            try await until("latest dispatch") { h.sink.attempts.count == 1 }
            try expect(h.predictor.maximumActive == 1 && h.sink.accepted.count == 1, "incorrect concurrency or dispatch count")
        }

        try await check("the model threshold, not question punctuation, controls dispatch") {
            let h = Harness(score: 0.79); defer { h.close() }
            h.controller.submit(input("Is this a question?"))
            try await until("below-threshold decision") { h.sink.decisions.count == 1 }
            try await pause(0.06)
            try expect(h.sink.attempts.isEmpty, "punctuation bypassed the model threshold")
            h.predictor.automaticScore = 0.8
            h.controller.submit(input("Explain the result in plain language."))
            try await until("threshold-inclusive dispatch") { h.sink.attempts.count == 1 }
            try expect(h.sink.accepted.count == 1, "inclusive default threshold rejected a model decision")
        }

        try await check("near-threshold explicit question waits for silence and dispatches once") {
            let h = Harness(score: 0.76, ruleNearMissMargin: 0.1); defer { h.close() }
            h.controller.setSpeaking(true, speaker: .room)
            h.controller.submit(input("你这个机制是怎么确定时间的", speaker: .room))
            try await until("near-threshold score") { h.sink.decisions.count == 1 }
            try await pause(0.06)
            try expect(h.sink.attempts.isEmpty, "active speech triggered analysis")
            h.controller.setSpeaking(false, speaker: .room)
            try await until("quiet near-threshold dispatch") { h.sink.attempts.count == 1 }
            try expect(h.sink.accepted.count == 1, "explicit question did not dispatch once")
            h.controller.submit(input("今天讨论这个机制的实现", speaker: .room))
            try await until("statement score") { h.sink.decisions.count == 2 }
            try await pause(0.06)
            try expect(h.sink.attempts.count == 1, "ordinary statement used near-miss fallback")
        }

        try await check("own transcripts are excluded and all active speakers must become quiet") {
            let h = Harness(score: 0.99); defer { h.close() }
            h.controller.submit(input("My own question?", speaker: .you))
            try await pause(0.02)
            try expect(h.predictor.calls.isEmpty && h.sink.attempts.isEmpty, "own speech was inferred or dispatched")
            h.controller.setSpeaking(true, speaker: .them)
            h.controller.setSpeaking(true, speaker: .room)
            h.controller.submit(input("Please describe this approach", speaker: .room))
            try await until("room decision") { h.sink.decisions.count == 1 }
            try await pause(0.06)
            try expect(h.sink.attempts.isEmpty, "active external speech dispatched")
            h.controller.setSpeaking(false, speaker: .them)
            try await pause(0.06)
            try expect(h.sink.attempts.isEmpty, "one quiet speaker hid another active speaker")
            h.controller.setSpeaking(false, speaker: .room)
            try await pause(0.012)
            try expect(h.sink.attempts.isEmpty, "speech end skipped the quiet window")
            try await until("quiet room dispatch") { h.sink.attempts.count == 1 }
            try expect(h.sink.accepted[0].speaker == .room, "room speaker was changed")
        }

        try await check("reset rejects cancellation-ignoring results and keeps the physical inference slot") {
            let h = Harness(); defer { h.close() }
            h.controller.submit(input("Old lifecycle request"))
            try await until("old prediction") { h.predictor.calls.count == 1 }
            h.controller.reset()
            h.controller.submit(input("New lifecycle request"))
            try await pause(0.05)
            try expect(h.predictor.calls.count == 1, "reset overlapped an uncooperative predictor")
            h.predictor.finish(0)
            try await until("new prediction") { h.predictor.calls.count == 2 }
            try expect(h.sink.attempts.isEmpty && h.sink.decisions.isEmpty, "reset emitted stale output")
            h.predictor.finish(1)
            try await until("new lifecycle dispatch") { h.sink.attempts.count == 1 }
            try expect(h.sink.accepted[0].text == "New lifecycle request" && h.predictor.maximumActive == 1,
                       "reset did not isolate lifecycle results")
            h.controller.reset()
            h.predictor.automaticScore = 0.95
            h.controller.submit(input("New lifecycle request"))
            try await until("reset cleared handled history") { h.sink.attempts.count == 2 }
        }

        try await check("disabled input and stale in-flight results cannot survive re-enabling") {
            let h = Harness(); defer { h.close() }
            h.controller.submit(input("Old enabled request"))
            try await until("old prediction") { h.predictor.calls.count == 1 }
            h.controller.configure(enabled: false)
            h.controller.submit(input("Ignored while disabled"))
            h.controller.configure(enabled: true, cooldown: 0)
            h.controller.submit(input("Old enabled request"))
            h.controller.submit(input("Fresh enabled request"))
            h.predictor.finish(0)
            try await until("fresh enabled prediction") { h.predictor.calls.count == 2 }
            try expect(h.predictor.calls[1].text == "Fresh enabled request", "disabled or replayed input survived")
            try expect(h.sink.attempts.isEmpty && h.sink.decisions.isEmpty, "disabled inference emitted output")
            h.predictor.finish(1)
            try await until("fresh dispatch") { h.sink.attempts.count == 1 }
            try expect(h.sink.accepted.count == 1 && h.predictor.maximumActive == 1, "enable lifecycle failed")
        }

        try await check("manual intervention retires both in-flight and queued questions") {
            let h = Harness(); defer { h.close() }
            h.controller.submit(input("In-flight question"))
            try await until("initial prediction") { h.predictor.calls.count == 1 }
            h.controller.submit(input("Queued question"))
            h.controller.manualIntervention()
            h.controller.submit(input("In-flight question"))
            h.controller.submit(input("Queued question"))
            h.predictor.finish(0)
            try await pause(0.08)
            try expect(h.predictor.calls.count == 1 && h.sink.attempts.isEmpty && h.sink.decisions.isEmpty,
                       "manual intervention replayed a retired question")
            h.predictor.automaticScore = 0.95
            h.controller.submit(input("A distinct follow-up"))
            try await until("new follow-up") { h.sink.attempts.count == 1 }
            try expect(h.sink.accepted[0].text == "A distinct follow-up", "manual intervention blocked fresh work")
        }

        try await check("own speech invalidates an in-flight result and stale final replays") {
            let h = Harness(); defer { h.close() }
            h.controller.submit(input("Question before my answer"))
            try await until("initial prediction") { h.predictor.calls.count == 1 }
            h.controller.setSpeaking(true, speaker: .you)
            h.controller.submit(input("Overlapping external question"))
            h.predictor.finish(0)
            try await pause(0.06)
            h.controller.setSpeaking(false, speaker: .you)
            h.controller.submit(input("Question before my answer"))
            h.controller.submit(input("Overlapping external question"))
            try await pause(0.06)
            try expect(h.sink.attempts.isEmpty && h.sink.decisions.isEmpty && h.predictor.calls.count == 1,
                       "own speech allowed an old question to trigger")
            h.predictor.automaticScore = 0.95
            h.controller.submit(input("A later question"))
            try await until("later dispatch") { h.sink.attempts.count == 1 }
        }

        try await check("own transcript without a speech event invalidates cached and in-flight work") {
            let h = Harness(); defer { h.close() }
            h.controller.submit(input("Question already answered aloud"))
            try await until("initial prediction") { h.predictor.calls.count == 1 }
            h.controller.submit(input("My answer", speaker: .you))
            h.predictor.finish(0)
            h.controller.retryPending()
            try await pause(0.08)
            try expect(h.sink.attempts.isEmpty && h.sink.decisions.isEmpty, "own transcript did not invalidate old work")
        }

        try await check("duplicate finals neither debounce nor repeat, including context and punctuation changes") {
            let h = Harness(score: 0.95, quiet: 0.04); defer { h.close() }
            h.controller.submit(input("Explain tradeoffs"))
            try await until("initial decision") { h.sink.decisions.count == 1 }
            for index in 0..<10 {
                h.controller.submit(input("  EXPLAIN   tradeoffs！  ", context: "replayed context \(index)"))
                h.controller.submit(input("Explain tradeoffs", final: false))
                try await pause(0.01)
            }
            try expect(h.sink.attempts.count == 1 && h.sink.accepted.count == 1,
                       "duplicates delayed, downgraded, or repeated a final")
            try expect(h.predictor.calls.count == 1, "duplicate final repeated model work")
            h.controller.submit(input("Explain tradeoffs?", speaker: .room))
            h.controller.retryPending()
            try await pause(0.05)
            try expect(h.sink.attempts.count == 1 && h.predictor.calls.count == 1, "handled question was not deduplicated")
        }

        try await check("deduplication preserves decimals and meaningful internal punctuation") {
            let h = Harness(score: 0.95, quiet: 0.015); defer { h.close() }
            h.controller.submit(input("Why is latency 1.5 ms?"))
            try await until("decimal question dispatch") { h.sink.attempts.count == 1 }
            h.controller.submit(input("Why is latency 15 ms?"))
            try await until("distinct numeric follow-up") { h.sink.attempts.count == 2 }
            try expect(h.sink.accepted.count == 2 && h.predictor.calls.count == 2,
                       "deduplication merged distinct numeric questions")
        }

        try await check("a replay of a superseded final cannot displace the latest question") {
            let h = Harness(); defer { h.close() }
            h.controller.submit(input("Older committed question"))
            try await until("older prediction") { h.predictor.calls.count == 1 }
            h.controller.submit(input("Latest committed question"))
            h.controller.submit(input("Older committed question", context: "replayed context"))
            h.predictor.finish(0)
            try await until("latest prediction") { h.predictor.calls.count == 2 }
            try expect(h.predictor.calls[1].text == "Latest committed question", "replayed final displaced latest input")
            h.predictor.finish(1)
            try await until("latest dispatch") { h.sink.attempts.count == 1 }
            try expect(h.sink.accepted[0].text == "Latest committed question", "obsolete question dispatched")
        }

        try await check("a new follow-up waits for cooldown then dispatches once without re-inference") {
            let h = Harness(score: 0.95, quiet: 0.02, cooldown: 0.14); defer { h.close() }
            h.controller.submit(input("First request"))
            try await until("first dispatch") { h.sink.attempts.count == 1 }
            h.controller.submit(input("New follow-up request"))
            try await until("follow-up score") { h.sink.decisions.count == 2 }
            try await pause(0.04)
            try expect(h.sink.attempts.count == 1, "follow-up bypassed cooldown")
            try await until("follow-up dispatch") { h.sink.attempts.count == 2 }
            try expect(h.sink.attemptTimes[1] - h.sink.attemptTimes[0] >= 0.138, "cooldown ended early")
            try expect(h.predictor.calls.count == 2 && h.sink.accepted.count == 2, "cooldown repeated inference or lost the follow-up")
        }

        try await check("prediction errors fail closed, do not retry automatically, and redact worker input") {
            let h = Harness(); defer { h.close() }
            h.controller.submit(input("A question with punctuation?"))
            try await until("prediction") { h.predictor.calls.count == 1 }
            h.predictor.fail(0)
            try await until("visible error") { h.sink.errors.count == 1 }
            for _ in 0..<3 { h.controller.retryPending() }
            h.controller.submit(input("A question with punctuation?"))
            try await pause(0.08)
            try expect(h.sink.attempts.isEmpty && h.predictor.calls.count == 1, "failed prediction fell back or retried")
            try expect(!h.sink.errors[0].contains("private synthetic input"), "worker error exposed transcript content")
            h.predictor.automaticScore = 0.95
            h.controller.submit(input("A fresh request after error"))
            try await until("recovery") { h.sink.attempts.count == 1 }
        }

        try await check("an independently cancelled worker reports failure for an active prediction") {
            let h = Harness(); defer { h.close() }
            h.controller.submit(input("Worker cancelled this request?"))
            try await until("prediction") { h.predictor.calls.count == 1 }
            h.predictor.cancel(0)
            try await until("worker cancellation error") { h.sink.errors.count == 1 }
            h.controller.retryPending()
            try await pause(0.06)
            try expect(h.sink.attempts.isEmpty && h.predictor.calls.count == 1,
                       "worker cancellation caused a fallback or automatic retry")
        }

        try await check("nonfinite and out-of-range confidence values never dispatch") {
            let h = Harness(); defer { h.close() }
            for (index, score) in [Double.nan, .infinity, -0.1, 1.1].enumerated() {
                h.controller.submit(input("Invalid confidence case \(index)?"))
                try await until("invalid prediction") { h.predictor.calls.count == index + 1 }
                h.predictor.finish(index, score: score)
                try await until("invalid score error") { h.sink.errors.count == index + 1 }
            }
            try await pause(0.05)
            try expect(h.sink.attempts.isEmpty && h.sink.decisions.isEmpty, "invalid probability escaped validation")
        }

        try await check("busy answer defers once and an explicit retry reuses the cached score") {
            let h = Harness(score: 0.95); defer { h.close() }
            h.sink.busy = true
            h.controller.submit(input("Deferred request"))
            try await until("busy attempt") { h.sink.attempts.count == 1 }
            try await pause(0.12)
            try expect(h.sink.attempts.count == 1 && h.sink.accepted.isEmpty, "busy callback was polled")
            h.sink.busy = false
            h.controller.retryPending()
            try await until("retry accepted") { h.sink.attempts.count == 2 }
            h.controller.retryPending()
            h.controller.submit(input("Deferred request"))
            try await pause(0.06)
            try expect(h.sink.attempts.count == 2 && h.sink.accepted.count == 1 && h.predictor.calls.count == 1,
                       "retry repeated inference or dispatched twice")
        }

        try await check("new input supersedes a busy deferred candidate") {
            let h = Harness(score: 0.95); defer { h.close() }
            h.sink.busy = true
            h.controller.submit(input("Older busy request"))
            try await until("older busy attempt") { h.sink.attempts.count == 1 }
            h.controller.submit(input("Latest busy request"))
            try await until("latest busy attempt") { h.sink.attempts.count == 2 }
            h.sink.busy = false
            h.controller.retryPending()
            try await until("latest accepted") { h.sink.attempts.count == 3 }
            try expect(h.sink.accepted.count == 1 && h.sink.accepted[0].text == "Latest busy request" &&
                       h.predictor.calls.count == 2, "busy retry used an obsolete candidate")
        }

        try await check("expired busy candidates cannot be revived by retries or duplicate finals") {
            let h = Harness(score: 0.95, quiet: 0.015, expiry: 0.12); defer { h.close() }
            h.sink.busy = true
            h.controller.submit(input("Soon expired request"))
            try await until("busy attempt") { h.sink.attempts.count == 1 }
            for index in 0..<6 {
                try await pause(0.025)
                h.controller.submit(input("Soon expired request", context: "duplicate \(index)"))
            }
            h.sink.busy = false
            h.controller.retryPending()
            try await pause(0.04)
            try expect(h.sink.attempts.count == 1 && h.sink.accepted.isEmpty && h.predictor.calls.count == 1,
                       "expired busy candidate was renewed")
        }

        try await check("expiry invalidates a slow cancellation-ignoring prediction") {
            let h = Harness(quiet: 0.01, expiry: 0.06); defer { h.close() }
            h.controller.submit(input("Slow request"))
            try await until("slow prediction") { h.predictor.calls.count == 1 }
            try await pause(0.08)
            h.predictor.finish(0)
            try await until("slow prediction settled") { h.predictor.active == 0 }
            h.controller.submit(input("Slow request"))
            h.controller.retryPending()
            try await pause(0.04)
            try expect(h.sink.attempts.isEmpty && h.sink.decisions.isEmpty && h.predictor.calls.count == 1,
                       "expired inference escaped or restarted")
        }

        try await check("revised context requires a new decision and cannot inherit a positive partial score") {
            let h = Harness(); defer { h.close() }
            h.controller.submit(input("Explain this decision", final: false, context: "still requested"))
            try await until("partial prediction") { h.predictor.calls.count == 1 }
            h.predictor.finish(0)
            try await until("positive partial") { h.sink.decisions.count == 1 }
            h.controller.submit(input("Explain this decision", context: "request withdrawn"))
            try await until("revised context prediction") { h.predictor.calls.count == 2 }
            try expect(h.predictor.calls[1].context == "request withdrawn", "latest context was ignored")
            h.predictor.finish(1, score: 0.05)
            try await until("negative final decision") { h.sink.decisions.count == 2 }
            try await pause(0.06)
            try expect(h.sink.attempts.isEmpty, "final reused a score from stale context")
        }

        try await check("manual intervention also cancels cached quiet timers and busy retries") {
            let h = Harness(score: 0.95, quiet: 0.08); defer { h.close() }
            h.controller.submit(input("Manually handled during quiet"))
            try await until("cached score") { h.sink.decisions.count == 1 }
            h.controller.manualIntervention()
            h.controller.retryPending()
            h.controller.submit(input("Manually handled during quiet"))
            try await pause(0.1)
            try expect(h.sink.attempts.isEmpty && h.predictor.calls.count == 1, "manual answer left a cached quiet timer")
            h.sink.busy = true
            h.controller.submit(input("Manually handled while busy"))
            try await until("busy attempt") { h.sink.attempts.count == 1 }
            h.controller.manualIntervention()
            h.sink.busy = false
            h.controller.retryPending()
            try await pause(0.1)
            try expect(h.sink.attempts.count == 1 && h.sink.accepted.isEmpty, "manual answer left a busy candidate")
        }

        try await check("threshold changes re-evaluate a cached decision without re-inference") {
            let h = Harness(); defer { h.close() }
            h.controller.submit(input("Threshold adjusted request"))
            try await until("prediction") { h.predictor.calls.count == 1 }
            h.controller.configure(enabled: true, threshold: 0.99, cooldown: 0)
            h.predictor.finish(0, score: 0.95)
            try await until("decision") { h.sink.decisions.count == 1 }
            try await pause(0.06)
            try expect(h.sink.attempts.isEmpty, "in-flight decision used obsolete threshold")
            h.controller.configure(enabled: true, threshold: 0.8, cooldown: 0)
            try await until("cached decision accepted") { h.sink.attempts.count == 1 }
            try expect(h.predictor.calls.count == 1, "threshold change repeated model work")
        }

        try await check("reentrant onDecision can invalidate a result before dispatch") {
            let h = Harness(score: 0.95); defer { h.close() }
            h.controller.onDecision = { [weak controller = h.controller, sink = h.sink] score in
                sink.decisions.append(score)
                controller?.manualIntervention()
            }
            h.controller.submit(input("Handled during decision callback"))
            try await until("decision callback") { h.sink.decisions.count == 1 }
            try await pause(0.08)
            try expect(h.sink.attempts.isEmpty, "callback invalidation was ignored")
        }

        try await check("stopping before the prediction task starts does not call the model") {
            let h = Harness(); defer { h.close() }
            h.controller.submit(input("Immediately stopped request"))
            h.controller.reset()
            try await pause(0.06)
            try expect(h.predictor.calls.isEmpty && h.sink.attempts.isEmpty, "cancelled queued task still called the model")
        }

        try await check("controller deallocation cancels pending work without retaining itself") {
            let predictor = Predictor(), sink = Sink()
            var controller: LayaTriggerController? = LayaTriggerController(
                predict: { try await predictor.predict($0, $1) }, onTrigger: { sink.receive($0) },
                timing: .init(throttle: 0.01, quiet: 0.02, expiry: 1))
            let isReleased = { [weak controller] in controller == nil }
            controller?.configure(enabled: true, cooldown: 0)
            controller?.submit(input("Controller released request"))
            try await until("prediction") { predictor.calls.count == 1 }
            controller = nil
            try expect(isReleased(), "task retained its controller across await")
            predictor.finish(0)
            try await pause(0.06)
            try expect(sink.attempts.isEmpty, "released controller dispatched")
        }
        return passed
    }
}

#if !XCODE_TESTS
@main struct LayaTriggerTestMain {
    @MainActor static func main() async {
        do {
            let checks = try await LayaTriggerChecks.run()
            checks.forEach { print("PASS \($0)") }
            print("\(checks.count) Laya trigger regression checks passed. No model downloads or real API calls.")
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }
}
#endif

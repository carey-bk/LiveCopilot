import Foundation

/// Content-free acoustic evidence for whether microphone speech is the far end replayed through
/// the speakers (Remote mode with speakers instead of headphones).
///
/// System audio is the exact signal the speakers play, so it is the echo reference. Both sources
/// are high-passed (laptop speakers reproduce little below a few hundred hertz, where speech energy
/// peaks) and reduced to 20 ms energy frames on the shared uptime clock; no audio is kept. A microphone
/// frame is `echo` when the recent microphone level contour follows the system contour at some
/// acoustic delay, `own` when the system was silent or the contours disagree (the user is talking,
/// including over the far end), and `unclear` in between. Decisions use durations of these
/// verdicts, never transcript text.
final class EchoMonitor: @unchecked Sendable {
    enum Source { case system, mic }
    enum Verdict: String, Codable { case echo, own, unclear }

    struct Assessment: Equatable {
        var echoMS = 0, ownMS = 0, unclearMS = 0
        /// Any system audio above the activity level near the assessed interval.
        var systemActive = false
        /// No system audio has arrived for a second: there is nothing to compare with.
        var referenceAbsent = false
        /// A recently learned acoustic coupling, required before text can support an echo decision.
        var echoPathKnown = false

        /// Enough microphone speech that the far end cannot explain (a silent far end included),
        /// and not outweighed by replay, or no reference at all. Scattered misjudged frames in a long
        /// replay therefore do not add up to the user's speech.
        ///
        /// Once this room's speaker-to-microphone path is known and the far end is audible, replay is
        /// proven possible here, so own evidence must at least match the replay: a third of loud
        /// frames in a replayed question (speaker and room colouring) no longer passes as the user.
        var isOwn: Bool {
            if referenceAbsent { return true }
            guard ownMS >= EchoMonitor.ownEvidenceMS else { return false }
            return systemActive && echoPathKnown ? ownMS >= echoMS : 2 * ownMS >= echoMS
        }
        /// Own evidence clearly outweighing replay; required to keep words that repeat the far end.
        var isStronglyOwn: Bool { referenceAbsent || (ownMS >= EchoMonitor.ownEvidenceMS && ownMS >= 2 * echoMS) }
        /// Mostly far-end replay.
        var isEcho: Bool { !referenceAbsent && systemActive && echoMS >= EchoMonitor.echoEvidenceMS && echoMS > 2 * ownMS }
        var verdict: Verdict { isOwn ? .own : isEcho ? .echo : .unclear }
    }

    /// Decision counters for diagnostics: numbers only.
    struct Counters: Equatable, Codable {
        /// Microphone turns held as possible echo; of those, later accepted as the user's.
        var heldTurns = 0, confirmedTurns = 0
        /// Finals discarded as echo, and finals kept although the evidence was unclear.
        var ignoredFinals = 0, unclearFinals = 0
        /// Of those decisions, made from timing plus text: replayed finals, and barge-ins confirmed.
        var textEchoFinals = 0, textOwnConfirms = 0
        /// Replayed finals discarded inside a turn already accepted as the user's (a reply after it).
        var confirmedTurnEchoFinals = 0
        /// Longest wait from a held turn's onset until it was accepted (double-talk latency).
        var confirmMSMax = 0
        /// Learned loudspeaker-to-microphone path, when echo was observed.
        var pathLagMS: Int?, pathGainDB: Int?
        /// Strongest microphone/system contour match seen (percent) and its delay, learned or not.
        var bestCorrelationPercent: Int?, bestLagMS: Int?
        /// Largest delivery delay after capture, per source: how late each stream reaches the app.
        var systemDelayMSMax = 0, micDelayMSMax = 0
        /// Speech-level microphone time by verdict, and why frames counted as the user: the far end
        /// was silent, or the frame was louder than the predicted replay.
        var echoFrameMS = 0, unclearFrameMS = 0, ownSilentFarEndMS = 0, ownLouderMS = 0
    }

    static let frameSeconds = 0.02
    static let ownEvidenceMS = 240
    static let echoEvidenceMS = 200
    /// Searched loudspeaker-to-microphone delay, including capture-callback timing differences
    /// and Bluetooth output latency. Negative values cover system audio that arrives late.
    static let lags = stride(from: -0.16, through: 0.6, by: 0.02).map { $0 }
    static let pathWindow = 1.5
    /// A real room (speaker response, reverberation, microphone processing) measured a best match
    /// of 0.77, so a path is learned from moderate matches that agree on the delay.
    static let pathCorrelation: Float = 0.65
    static let pathVotes = 6
    /// Without a learned path a strong match is echo; anything else is unclear, never the user:
    /// a real room matched at most 0.77, and independent speech can match moderately by chance.
    static let fallbackEchoCorrelation: Float = 0.75
    static let highPassHz = 300.0
    static let pathLifetime: TimeInterval = 20
    static let systemActiveDB: Float = -50
    /// Microphone frames this far above the predicted echo are the user; at most this far, echo.
    static let ownExcessDB: Float = 4
    static let echoExcessDB: Float = 2
    static let reverb = 0.4
    static let reverbDecayDBPerSecond: Float = 75

    private struct Frame {
        let sequence: UInt64; let time: TimeInterval; let db: Float
        var classified = false; var verdict: Verdict?
        /// Own because the far end was silent at every plausible delay (diagnostics only).
        var farEndSilent = false
    }
    private struct Track {
        var frames: [Frame] = []
        var sum = 0.0, count = 0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    }
    /// Second-order Butterworth high-pass coefficients (b0, b1, b2, a1, a2).
    private var filter = (0.0, 0.0, 0.0, 0.0, 0.0)

    private let lock = NSLock()
    /// Serializes `assess` callers only. Without it, an overlapping caller could commit an older
    /// snapshot's floor, path and votes over a newer one. Capture threads never take this lock.
    private let classifyLock = NSLock()
    private var sessionGeneration: UInt64 = 0
    private var nextFrameSequence: UInt64 = 0
    private var frameSamples = 320
    private var system = Track(), mic = Track()
    private var counters = Counters()
    /// Microphone noise floor: falls instantly, rises 2.5 dB/s, so it tracks pauses between words.
    private var floorDB: Float?
    private struct Path { let lag: TimeInterval; let gainDB: Float; let updatedAt: TimeInterval }
    private var path: Path?
    private var lagVotes: [Double] = [], gainVotes: [Float] = []

    func begin(sampleRate: Double) {
        lock.withLock {
            sessionGeneration &+= 1
            nextFrameSequence = 0
            frameSamples = max(1, Int(sampleRate * Self.frameSeconds))
            let w = 2 * Double.pi * min(Self.highPassHz, sampleRate / 4) / max(1, sampleRate)
            let alpha = sin(w) / (2 * 0.5.squareRoot()), c = cos(w), a0 = 1 + alpha
            filter = ((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0)
            system = Track(); mic = Track(); counters = Counters(); floorDB = nil
            path = nil; lagVotes = []; gainVotes = []
        }
    }

    /// End of a captured buffer on the uptime clock. Capture timestamps (host time) align the two
    /// sources; arrival time does not, because each stream reaches the app with its own delay.
    /// Falls back to `now` for a missing or implausible timestamp.
    static func captureEnd(start: TimeInterval?, duration: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        guard let start, start.isFinite, duration.isFinite, abs(start + duration - now) < 2 else { return now }
        return start + duration
    }

    /// PCM16 mono little-endian, called on capture threads. `time` is when the last sample of
    /// `data` was captured, on the uptime clock (see `captureEnd`).
    func observe(_ data: Data, source: Source, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let count = data.count / 2
        guard count > 0 else { return }
        let delay = Int(max(0, ProcessInfo.processInfo.systemUptime - time) * 1000)
        lock.withLock {
            if source == .system {
                counters.systemDelayMSMax = max(counters.systemDelayMSMax, delay)
                appendSamples(data, count: count, at: time, to: &system)
            } else {
                counters.micDelayMSMax = max(counters.micDelayMSMax, delay)
                appendSamples(data, count: count, at: time, to: &mic)
            }
        }
    }

    private func appendSamples(_ data: Data, count: Int, at time: TimeInterval, to track: inout Track) {
        let rate = Double(frameSamples) / Self.frameSeconds
        let (b0, b1, b2, a1, a2) = filter
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<count {
                let input = Double(Int16(littleEndian: samples[index])) / 32768
                let value = b0 * input + b1 * track.x1 + b2 * track.x2 - a1 * track.y1 - a2 * track.y2
                track.x2 = track.x1; track.x1 = input; track.y2 = track.y1; track.y1 = value
                track.sum += value * value; track.count += 1
                guard track.count == frameSamples else { continue }
                let rms = (track.sum / Double(track.count)).squareRoot()
                let db = rms > 0 ? Float(max(-90, 20 * log10(rms))) : -90
                nextFrameSequence &+= 1
                track.frames.append(Frame(sequence: nextFrameSequence, time: time - Double(count - 1 - index) / rate, db: db))
                track.sum = 0; track.count = 0
            }
        }
        // About 8 s per source, enough for the longest assessed turn window.
        if track.frames.count > 480 { track.frames.removeFirst(track.frames.count - 400) }
    }

    /// Microphone verdict durations for frames captured in `start...end`, judged only as far as
    /// the system reference has arrived (it is delivered later than the microphone).
    func assess(from start: TimeInterval, to requestedEnd: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Assessment {
        classifyLock.lock(); defer { classifyLock.unlock() }
        // 1. Short lock: snapshot value-type state so real-time audio threads are never blocked
        //    by the multi-lag correlation loops below.
        var state = lock.withLock {
            ClassifierState(
                generation: sessionGeneration,
                systemFrames: system.frames,
                micFrames: mic.frames,
                floorDB: floorDB,
                path: path,
                lagVotes: lagVotes,
                gainVotes: gainVotes,
                bestCorrelationPercent: counters.bestCorrelationPercent,
                bestLagMS: counters.bestLagMS
            )
        }

        // 2. Lock-free classification and assessment on pure value-type copies.
        state.classify(now: now)
        let result = state.assessment(from: start, to: requestedEnd, now: now)

        // 3. Short lock: commit newly classified verdicts and learned path state if session is unchanged.
        if state.didClassify {
            lock.withLock {
                guard sessionGeneration == state.generation else { return }
                var snapIndex = 0
                let snapCount = state.micFrames.count
                for index in mic.frames.indices {
                    let seq = mic.frames[index].sequence
                    while snapIndex < snapCount && state.micFrames[snapIndex].sequence < seq {
                        snapIndex += 1
                    }
                    guard snapIndex < snapCount else { break }
                    if state.micFrames[snapIndex].sequence == seq,
                       !mic.frames[index].classified,
                       state.micFrames[snapIndex].classified {
                        let frame = state.micFrames[snapIndex]
                        mic.frames[index].classified = true
                        mic.frames[index].verdict = frame.verdict
                        mic.frames[index].farEndSilent = frame.farEndSilent
                        let ms = Int(Self.frameSeconds * 1000)
                        switch frame.verdict {
                        case .echo: counters.echoFrameMS += ms
                        case .unclear: counters.unclearFrameMS += ms
                        case .own: if frame.farEndSilent { counters.ownSilentFarEndMS += ms } else { counters.ownLouderMS += ms }
                        case nil: break
                        }
                    }
                }
                floorDB = state.floorDB
                path = state.path
                lagVotes = state.lagVotes
                gainVotes = state.gainVotes
                if state.bestCorrelationUpdated, let bestCorr = state.bestCorrelationPercent {
                    let current = counters.bestCorrelationPercent ?? Int.min
                    if bestCorr >= current {
                        counters.bestCorrelationPercent = bestCorr
                        counters.bestLagMS = state.bestLagMS
                    }
                }
            }
        }

        return result
    }

    func note(_ update: (inout Counters) -> Void) { lock.withLock { update(&counters) } }
    var snapshot: Counters {
        lock.withLock {
            var result = counters
            if let path { result.pathLagMS = Int((path.lag * 1000).rounded()); result.pathGainDB = Int(path.gainDB.rounded()) }
            return result
        }
    }

    // MARK: - Classification (lock-free value-type snapshot)

    /// Pure value-type snapshot used by `assess(from:to:now:)` so the compiler statically guarantees
    /// no shared mutable state on `EchoMonitor` is touched outside `lock`.
    private struct ClassifierState {
        let generation: UInt64
        let systemFrames: [Frame]
        var micFrames: [Frame]
        var floorDB: Float?
        var path: Path?
        var lagVotes: [Double]
        var gainVotes: [Float]
        var bestCorrelationPercent: Int?
        var bestLagMS: Int?
        var didClassify = false
        var bestCorrelationUpdated = false

        mutating func classify(now: TimeInterval) {
            // A microphone frame is judged once the system frames it may be compared with have
            // arrived (the reference stream can be delivered later), or after a second without them.
            let covered = (systemFrames.last?.time ?? -.infinity) + (EchoMonitor.lags.first ?? 0) - EchoMonitor.frameSeconds
            let ready = max(covered, now - 1)
            for index in micFrames.indices where !micFrames[index].classified && micFrames[index].time <= ready {
                didClassify = true
                let db = micFrames[index].db
                let floor = floorDB.map { db < $0 ? db : min($0 + 0.05, db) } ?? db
                floorDB = floor
                micFrames[index].classified = true
                // Speech-level microphone frames only; room noise and pauses carry no evidence.
                guard db > max(-62, floor + 9) else { continue }
                micFrames[index].verdict = verdict(at: index)
            }
        }

        func assessment(from start: TimeInterval, to requestedEnd: TimeInterval, now: TimeInterval) -> Assessment {
            var result = Assessment()
            let latest = systemFrames.last?.time
            let present = latest.map { now - $0 < 1 } ?? false
            result.referenceAbsent = !present
            result.echoPathKnown = path.map { now - $0.updatedAt < EchoMonitor.pathLifetime } ?? false
            let end = present ? min(requestedEnd, latest ?? requestedEnd) : requestedEnd
            let frameMS = Int(EchoMonitor.frameSeconds * 1000)
            for frame in micFrames where frame.time >= start && frame.time <= end {
                switch frame.verdict {
                case .echo: result.echoMS += frameMS
                case .own: result.ownMS += frameMS
                case .unclear: result.unclearMS += frameMS
                case nil: break
                }
            }
            result.systemActive = systemFrames.contains { $0.time >= start - 0.5 && $0.time <= end && $0.db > EchoMonitor.systemActiveDB }
            return result
        }

        private mutating func verdict(at index: Int) -> Verdict {
            let frame = micFrames[index]
            let t = frame.time
            // Far end silent at every plausible delay (reverberation included): nothing to echo.
            guard systemPeak(from: t - (EchoMonitor.lags.last ?? 0) - EchoMonitor.reverb, to: t - (EchoMonitor.lags.first ?? 0)) > EchoMonitor.systemActiveDB else {
                micFrames[index].farEndSilent = true
                return .own
            }
            if index % 5 == 0 { learnPath(at: index) }
            if let path, t - path.updatedAt < EchoMonitor.pathLifetime {
                // Energy the far end can explain at this delay, with a reverberation decay. Speech
                // clearly louder than that is the user, including over the far end (double talk).
                let excess = frame.db - (predictedEcho(at: t - path.lag) + path.gainDB)
                if excess > EchoMonitor.ownExcessDB { return .own }
                return excess <= EchoMonitor.echoExcessDB ? .echo : .unclear
            }
            // No echo path observed yet (for example headphones): only a strong contour match decides.
            return bestCorrelation(at: index).value >= EchoMonitor.fallbackEchoCorrelation ? .echo : .unclear
        }

        /// Learns the loudspeaker-to-microphone delay and coupling while the microphone clearly
        /// follows the far end. Votes are bounded; the path expires when no echo is seen.
        private mutating func learnPath(at index: Int) {
            let (lag, value) = bestCorrelation(at: index)
            if value > Float(bestCorrelationPercent ?? -100) / 100 {
                bestCorrelationPercent = Int((value * 100).rounded())
                bestLagMS = Int((lag * 1000).rounded())
                bestCorrelationUpdated = true
            }
            guard value >= EchoMonitor.pathCorrelation else { return }
            let end = micFrames[index].time
            let window = micFrames[...index].reversed().prefix { end - $0.time < EchoMonitor.pathWindow }
            let floor = max(-62, (floorDB ?? -90) + 9)
            let gains = window.compactMap { frame -> Float? in
                let reference = systemDB(at: frame.time - lag)
                return frame.db > floor && reference > EchoMonitor.systemActiveDB ? frame.db - reference : nil
            }.sorted()
            guard gains.count >= 10 else { return }
            lagVotes = Array((lagVotes + [lag]).suffix(30))
            gainVotes = Array((gainVotes + [gains[gains.count / 2]]).suffix(30))
            // A path needs repeated matches at one delay (±20 ms), most of the recent ones; unrelated
            // speech scatters its lags.
            let buckets = lagVotes.map { Int(($0 * 50).rounded()) }
            // Candidates in ascending order so a tie always resolves to the shorter delay: a Set's
            // iteration order is randomized per instance, which made the learned delay vary.
            guard let mode = Set(buckets).sorted().max(by: { a, b in
                buckets.filter { abs($0 - a) <= 1 }.count < buckets.filter { abs($0 - b) <= 1 }.count
            }) else { return }
            let agreeing = buckets.filter { abs($0 - mode) <= 1 }.count
            guard agreeing >= EchoMonitor.pathVotes, 2 * agreeing >= buckets.count else { return }
            let sortedGains = gainVotes.sorted()
            path = Path(lag: Double(mode) / 50, gainDB: sortedGains[sortedGains.count / 2], updatedAt: end)
        }

        private func bestCorrelation(at index: Int) -> (lag: Double, value: Float) {
            let end = micFrames[index].time
            let window = Array(micFrames[...index].reversed().prefix { end - $0.time < EchoMonitor.pathWindow })
            guard window.count >= 20 else { return (0, -1) }
            let micDB = window.map(\.db)
            var best: (lag: Double, value: Float) = (0, -1)
            for lag in EchoMonitor.lags {
                let reference = window.map { systemDB(at: $0.time - lag) }
                guard let peak = reference.max(), peak > EchoMonitor.systemActiveDB else { continue }
                let value = EchoMonitor.correlation(micDB, reference)
                if value > best.value { best = (lag, value) }
            }
            return best
        }

        /// Far-end level that can still be heard at `time`, decaying like room reverberation.
        private func predictedEcho(at time: TimeInterval) -> Float {
            var best: Float = -90
            var age = -0.04
            while age <= EchoMonitor.reverb {
                best = max(best, systemDB(at: time - age) - Float(max(0, age)) * EchoMonitor.reverbDecayDBPerSecond)
                age += EchoMonitor.frameSeconds
            }
            return best
        }

        private func systemPeak(from start: TimeInterval, to end: TimeInterval) -> Float {
            systemFrames.lazy.filter { $0.time >= start && $0.time <= end }.map(\.db).max() ?? -90
        }

        private func systemDB(at time: TimeInterval) -> Float {
            let frames = systemFrames
            var low = 0, high = frames.count
            while low < high {
                let mid = (low + high) / 2
                if frames[mid].time < time { low = mid + 1 } else { high = mid }
            }
            var bestDB: Float = -90, bestDistance = EchoMonitor.frameSeconds / 2 + 1e-6
            for candidate in [low - 1, low] where frames.indices.contains(candidate) {
                let distance = abs(frames[candidate].time - time)
                if distance <= bestDistance { bestDistance = distance; bestDB = frames[candidate].db }
            }
            return bestDB
        }
    }

    static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        guard a.count == b.count, a.count > 1 else { return 0 }
        let meanA = a.reduce(0, +) / n, meanB = b.reduce(0, +) / n
        var covariance: Float = 0, varianceA: Float = 0, varianceB: Float = 0
        for i in a.indices {
            let x = a[i] - meanA, y = b[i] - meanB
            covariance += x * y; varianceA += x * x; varianceB += y * y
        }
        guard varianceA > 1e-3, varianceB > 1e-3 else { return 0 }
        return covariance / (varianceA * varianceB).squareRoot()
    }
}

extension EchoMonitor.Counters {
    /// Journal records written before a counter existed still decode; missing counters read as zero.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) throws -> Int { try c.decodeIfPresent(Int.self, forKey: key) ?? 0 }
        self.init()
        heldTurns = try int(.heldTurns); confirmedTurns = try int(.confirmedTurns)
        ignoredFinals = try int(.ignoredFinals); unclearFinals = try int(.unclearFinals)
        textEchoFinals = try int(.textEchoFinals); textOwnConfirms = try int(.textOwnConfirms)
        confirmedTurnEchoFinals = try int(.confirmedTurnEchoFinals); confirmMSMax = try int(.confirmMSMax)
        pathLagMS = try c.decodeIfPresent(Int.self, forKey: .pathLagMS)
        pathGainDB = try c.decodeIfPresent(Int.self, forKey: .pathGainDB)
        bestCorrelationPercent = try c.decodeIfPresent(Int.self, forKey: .bestCorrelationPercent)
        bestLagMS = try c.decodeIfPresent(Int.self, forKey: .bestLagMS)
        systemDelayMSMax = try int(.systemDelayMSMax); micDelayMSMax = try int(.micDelayMSMax)
        echoFrameMS = try int(.echoFrameMS); unclearFrameMS = try int(.unclearFrameMS)
        ownSilentFarEndMS = try int(.ownSilentFarEndMS); ownLouderMS = try int(.ownLouderMS)
    }
}

/// How much of a microphone transcript repeats what the far end's recognizer heard. Only used
/// together with timing: the far end must have been audible during the microphone turn, and
/// acoustic evidence of the user's own voice always wins, so a user who repeats or quotes the other
/// side after it stops is never discarded. Text is compared in memory only, never stored or logged.
enum EchoText {
    /// At least this share of the microphone's tokens also in the far end's recent text: replay.
    static let echoSimilarity = 0.6
    /// At most this share, with enough tokens: different words, so the user's own speech.
    static let ownSimilarity = 0.3
    static let minimumOwnTokens = 6

    /// CJK text compares character bigrams; other text compares lowercased words.
    static func tokens(_ text: String) -> [String] {
        let kept = text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        let cleaned = String(String.UnicodeScalarView(kept))
        let cjk = cleaned.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
        if cjk.count * 2 >= cleaned.unicodeScalars.filter({ $0 != " " }).count, cjk.count >= 2 {
            let characters = Array(cleaned.replacingOccurrences(of: " ", with: ""))
            return characters.count < 2 ? characters.map(String.init) : (0..<(characters.count - 1)).map { String(characters[$0...$0 + 1]) }
        }
        return cleaned.split(separator: " ").map(String.init)
    }

    /// Rescue a distinct reply following a long verbatim Mandarin replay in one ASR
    /// segment. Require actual mixed audio evidence; never strip a quotation on text alone.
    /// Only trim at the leading edge: word-by-word subtraction invents sentences.
    static func mixedReply(_ text: String, references: [String], assessment: EchoMonitor.Assessment) -> String? {
        guard assessment.systemActive, assessment.echoMS >= EchoMonitor.echoEvidenceMS,
              assessment.ownMS >= 120, !references.isEmpty, text.count <= 512 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = trimmed.prefix { ch in ch.unicodeScalars.allSatisfy { (0x3400...0x9fff).contains($0.value) } }
        guard prefix.count >= 8 else { return nil }
        let unique = Set(references.suffix(16).map { String($0.suffix(768)) })
        var best = 0
        for ref in unique {
            var lo = best + 1, hi = prefix.count
            while lo <= hi {
                let n = (lo + hi) / 2
                if ref.contains(String(prefix.prefix(n))) { best = max(best, n); lo = n + 1 } else { hi = n - 1 }
            }
        }
        guard best >= 8 else { return nil }
        let rest = String(trimmed.dropFirst(best)).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let remaining = tokens(rest), known = Set(unique.flatMap(tokens))
        // A reply can reuse words from the question ("介绍一下"); require new
        // material at its beginning and a majority of independently recognized pairs.
        guard remaining.count >= 2, remaining.prefix(2).allSatisfy({ !known.contains($0) }),
              remaining.filter({ !known.contains($0) }).count * 2 > remaining.count else { return nil }
        // A shared modifier can belong to the user's following noun. A matched
        // prefix ending in 的 is an ambiguous cut (最难解决的 | 部分). Keep
        // the modifier when there is a clear start, otherwise retain the ASR text.
        let matched = trimmed.prefix(best)
        if matched.last == "的" {
            guard let marker = matched.lastIndex(of: "最"),
                  matched.distance(from: marker, to: matched.endIndex) <= 10 else { return nil }
            return String(trimmed[marker...])
        }
        return rest
    }

    /// Share of `text`'s tokens found in any of `recent`; nil when either side has no tokens.
    static func similarity(_ text: String, to recent: [String]) -> Double? {
        let mine = tokens(text)
        let theirs = Set(recent.flatMap(tokens))
        guard !mine.isEmpty, !theirs.isEmpty else { return nil }
        return Double(mine.filter(theirs.contains).count) / Double(mine.count)
    }
}

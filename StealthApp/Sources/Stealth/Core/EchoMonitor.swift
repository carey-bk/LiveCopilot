import Foundation

/// Content-free acoustic evidence for whether microphone speech is the far end replayed through
/// the speakers (Remote mode with speakers instead of headphones).
///
/// System audio is the exact signal the speakers play, so it is the echo reference. Both sources
/// are reduced to 20 ms energy frames on the shared uptime clock; no audio is kept. A microphone
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

        /// Enough microphone speech that does not follow the far end, or no far end at all.
        var isOwn: Bool { !systemActive || ownMS >= EchoMonitor.ownEvidenceMS }
        /// Mostly far-end replay with too little independent speech to be the user.
        var isEcho: Bool {
            systemActive && ownMS < EchoMonitor.ownEvidenceMS && echoMS >= EchoMonitor.echoEvidenceMS && echoMS >= 3 * ownMS
        }
        var verdict: Verdict { isOwn ? .own : isEcho ? .echo : .unclear }
    }

    /// Decision counters for diagnostics: numbers only.
    struct Counters: Equatable, Codable {
        /// Microphone turns held as possible echo; of those, later accepted as the user's.
        var heldTurns = 0, confirmedTurns = 0
        /// Finals discarded as echo, and finals kept although the evidence was unclear.
        var ignoredFinals = 0, unclearFinals = 0
        /// Longest wait from a held turn's onset until it was accepted (double-talk latency).
        var confirmMSMax = 0
        /// Learned loudspeaker-to-microphone path, when echo was observed.
        var pathLagMS: Int?, pathGainDB: Int?
    }

    static let frameSeconds = 0.02
    static let ownEvidenceMS = 240
    static let echoEvidenceMS = 200
    /// Searched loudspeaker-to-microphone delay, including capture-callback timing differences
    /// and Bluetooth output latency. Negative values cover system audio that arrives late.
    static let lags = stride(from: -0.16, through: 0.48, by: 0.02).map { $0 }
    static let pathWindow = 1.0
    static let pathCorrelation: Float = 0.8
    static let pathLifetime: TimeInterval = 20
    static let systemActiveDB: Float = -50
    /// Microphone frames this far above the predicted echo are the user; at most this far, echo.
    static let ownExcessDB: Float = 4
    static let echoExcessDB: Float = 2
    static let reverb = 0.4
    static let reverbDecayDBPerSecond: Float = 75

    private struct Frame { let time: TimeInterval; let db: Float; var classified = false; var verdict: Verdict? }
    private struct Track {
        var frames: [Frame] = []
        var sum = 0.0, count = 0
    }

    private let lock = NSLock()
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
            frameSamples = max(1, Int(sampleRate * Self.frameSeconds))
            system = Track(); mic = Track(); counters = Counters(); floorDB = nil
            path = nil; lagVotes = []; gainVotes = []
        }
    }

    /// PCM16 mono little-endian, called on capture threads. `time` is the uptime at which the last
    /// sample of `data` arrived.
    func observe(_ data: Data, source: Source, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let count = data.count / 2
        guard count > 0 else { return }
        lock.withLock {
            let rate = Double(frameSamples) / Self.frameSeconds
            var track = source == .system ? system : mic
            data.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for index in 0..<count {
                    let value = Double(Int16(littleEndian: samples[index])) / 32768
                    track.sum += value * value; track.count += 1
                    guard track.count == frameSamples else { continue }
                    let rms = (track.sum / Double(track.count)).squareRoot()
                    let db = rms > 0 ? Float(max(-90, 20 * log10(rms))) : -90
                    track.frames.append(Frame(time: time - Double(count - 1 - index) / rate, db: db))
                    track.sum = 0; track.count = 0
                }
            }
            // About 8 s per source, enough for the longest assessed turn window.
            if track.frames.count > 480 { track.frames.removeFirst(track.frames.count - 400) }
            if source == .system { system = track } else { mic = track }
        }
    }

    /// Microphone verdict durations for frames arriving in `start...end`.
    func assess(from start: TimeInterval, to end: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Assessment {
        lock.withLock {
            classify(now: now)
            var result = Assessment()
            let frameMS = Int(Self.frameSeconds * 1000)
            for frame in mic.frames where frame.time >= start && frame.time <= end {
                switch frame.verdict {
                case .echo: result.echoMS += frameMS
                case .own: result.ownMS += frameMS
                case .unclear: result.unclearMS += frameMS
                case nil: break
                }
            }
            result.systemActive = system.frames.contains { $0.time >= start - 0.5 && $0.time <= end && $0.db > Self.systemActiveDB }
            return result
        }
    }

    func note(_ update: (inout Counters) -> Void) { lock.withLock { update(&counters) } }
    var snapshot: Counters {
        lock.withLock {
            var result = counters
            if let path { result.pathLagMS = Int((path.lag * 1000).rounded()); result.pathGainDB = Int(path.gainDB.rounded()) }
            return result
        }
    }

    // MARK: - Classification (under lock)

    private func classify(now: TimeInterval) {
        // Leave time for late-arriving system frames at the most negative lag.
        let ready = now + (Self.lags.first ?? 0) - Self.frameSeconds
        for index in mic.frames.indices where !mic.frames[index].classified && mic.frames[index].time <= ready {
            let db = mic.frames[index].db
            let floor = floorDB.map { db < $0 ? db : min($0 + 0.05, db) } ?? db
            floorDB = floor
            mic.frames[index].classified = true
            // Speech-level microphone frames only; room noise and pauses carry no evidence.
            guard db > max(-62, floor + 9) else { continue }
            mic.frames[index].verdict = verdict(at: index)
        }
    }

    private func verdict(at index: Int) -> Verdict {
        let frame = mic.frames[index]
        let t = frame.time
        // Far end silent at every plausible delay (reverberation included): nothing to echo.
        guard systemPeak(from: t - (Self.lags.last ?? 0) - Self.reverb, to: t - (Self.lags.first ?? 0)) > Self.systemActiveDB else { return .own }
        if index % 5 == 0 { learnPath(at: index) }
        if let path, t - path.updatedAt < Self.pathLifetime {
            // Energy the far end can explain at this delay, with a reverberation decay. Speech
            // clearly louder than that is the user, including over the far end (double talk).
            let excess = frame.db - (predictedEcho(at: t - path.lag) + path.gainDB)
            if excess > Self.ownExcessDB { return .own }
            return excess <= Self.echoExcessDB ? .echo : .unclear
        }
        // No echo path observed yet (for example headphones): only a sustained contour match counts.
        return bestCorrelation(at: index).value >= Self.pathCorrelation ? .echo : .own
    }

    /// Learns the loudspeaker-to-microphone delay and coupling while the microphone clearly
    /// follows the far end. Votes are bounded; the path expires when no echo is seen.
    private func learnPath(at index: Int) {
        let (lag, value) = bestCorrelation(at: index)
        guard value >= Self.pathCorrelation else { return }
        let end = mic.frames[index].time
        let window = mic.frames[...index].reversed().prefix { end - $0.time < Self.pathWindow }
        let floor = max(-62, (floorDB ?? -90) + 9)
        let gains = window.compactMap { frame -> Float? in
            let reference = systemDB(at: frame.time - lag)
            return frame.db > floor && reference > Self.systemActiveDB ? frame.db - reference : nil
        }.sorted()
        guard gains.count >= 10 else { return }
        lagVotes = Array((lagVotes + [lag]).suffix(30))
        gainVotes = Array((gainVotes + [gains[gains.count / 2]]).suffix(30))
        let counts = Dictionary(grouping: lagVotes) { ($0 * 50).rounded() }.mapValues(\.count)
        let modeLag = (counts.max { $0.value < $1.value }?.key ?? (lag * 50).rounded()) / 50
        let sortedGains = gainVotes.sorted()
        path = Path(lag: modeLag, gainDB: sortedGains[sortedGains.count / 2], updatedAt: end)
    }

    private func bestCorrelation(at index: Int) -> (lag: Double, value: Float) {
        let end = mic.frames[index].time
        let window = Array(mic.frames[...index].reversed().prefix { end - $0.time < Self.pathWindow })
        guard window.count >= 20 else { return (0, -1) }
        let micDB = window.map(\.db)
        var best: (lag: Double, value: Float) = (0, -1)
        for lag in Self.lags {
            let reference = window.map { systemDB(at: $0.time - lag) }
            guard let peak = reference.max(), peak > Self.systemActiveDB else { continue }
            let value = Self.correlation(micDB, reference)
            if value > best.value { best = (lag, value) }
        }
        return best
    }

    /// Far-end level that can still be heard at `time`, decaying like room reverberation.
    private func predictedEcho(at time: TimeInterval) -> Float {
        var best: Float = -90
        var age = -0.04
        while age <= Self.reverb {
            best = max(best, systemDB(at: time - age) - Float(max(0, age)) * Self.reverbDecayDBPerSecond)
            age += Self.frameSeconds
        }
        return best
    }

    private func systemPeak(from start: TimeInterval, to end: TimeInterval) -> Float {
        system.frames.lazy.filter { $0.time >= start && $0.time <= end }.map(\.db).max() ?? -90
    }

    private func systemDB(at time: TimeInterval) -> Float {
        let frames = system.frames
        var low = 0, high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].time < time { low = mid + 1 } else { high = mid }
        }
        var bestDB: Float = -90, bestDistance = Self.frameSeconds / 2 + 1e-6
        for candidate in [low - 1, low] where frames.indices.contains(candidate) {
            let distance = abs(frames[candidate].time - time)
            if distance <= bestDistance { bestDistance = distance; bestDB = frames[candidate].db }
        }
        return bestDB
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

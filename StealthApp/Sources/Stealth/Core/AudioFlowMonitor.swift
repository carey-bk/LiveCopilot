import Foundation

/// Content-free accounting for one capture source. It separates "no audio arrived",
/// "audio arrived but was digital silence" and "audio arrived but produced no text", and
/// measures how long recognition takes to show the first text of each utterance.
/// `observe` runs on the capture callback thread and only keeps counters; audio is never stored.
final class AudioFlowMonitor: @unchecked Sendable {
    enum Verdict: String, Codable { case noAudio, digitalSilence, audioWithoutText, recognized }
    struct Snapshot: Equatable {
        var verdict: Verdict
        var audioSeconds: Double
        /// From `begin` to the first PCM chunk.
        var firstAudioMS: Int?
        /// Loudest sample, in whole dBFS. -96 means every sample was exactly zero.
        var peakDBFS: Int?
        /// Share of chunks whose peak exceeds -60 dBFS, a level any open microphone reaches.
        var audibleFraction: Double
        var partials: Int
        var transcripts: Int
        /// Speech onset to the first partial or final text of the same utterance.
        var textLatencyMeanMS: Int?
        var textLatencyMaxMS: Int?
    }
    static let audibleThreshold: Int16 = 33 // about -60 dBFS

    private let lock = NSLock()
    private let clock: () -> TimeInterval
    private var sampleRate: Double = 16_000
    private var startedAt: TimeInterval = 0
    private var firstAudioAt: TimeInterval?
    private var samples = 0
    private var chunks = 0
    private var audibleChunks = 0
    private var peak: Int32 = 0
    private var partials = 0
    private var transcripts = 0
    private var speechStartedAt: TimeInterval?
    private var latencyCount = 0
    private var latencySum: TimeInterval = 0
    private var latencyMax: TimeInterval = 0

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

    func begin(sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        self.sampleRate = sampleRate > 0 ? sampleRate : 16_000
        startedAt = clock(); firstAudioAt = nil
        samples = 0; chunks = 0; audibleChunks = 0; peak = 0
        partials = 0; transcripts = 0; speechStartedAt = nil
        latencyCount = 0; latencySum = 0; latencyMax = 0
    }

    /// Little-endian mono PCM16, as produced by `PCMConverter`.
    func observe(_ pcm: Data) {
        var chunkPeak: Int32 = 0
        pcm.withUnsafeBytes { raw in
            var offset = 0
            while offset + 1 < raw.count {
                let value = Int32(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
                chunkPeak = max(chunkPeak, abs(value))
                offset += 2
            }
        }
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        if firstAudioAt == nil { firstAudioAt = now }
        samples += pcm.count / 2; chunks += 1
        if chunkPeak > Int32(Self.audibleThreshold) { audibleChunks += 1 }
        peak = max(peak, chunkPeak)
    }

    /// A new onset replaces one that never produced text (a cough, or speech below recognition).
    func speechStarted() {
        lock.lock(); defer { lock.unlock() }
        speechStartedAt = clock()
    }
    func notePartial() { noteText(final: false) }
    func noteTranscript() { noteText(final: true) }
    private func noteText(final: Bool) {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        if final { transcripts += 1 } else { partials += 1 }
        if let started = speechStartedAt {
            let latency = max(0, now - started)
            latencyCount += 1; latencySum += latency; latencyMax = max(latencyMax, latency)
            speechStartedAt = nil
        }
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let verdict: Verdict = chunks == 0 ? .noAudio : peak == 0 ? .digitalSilence
            : partials + transcripts == 0 ? .audioWithoutText : .recognized
        let peakDBFS = chunks == 0 ? nil : peak == 0 ? -96 : Int((20 * log10(Double(peak) / 32_768)).rounded())
        return Snapshot(verdict: verdict,
                        audioSeconds: (Double(samples) / sampleRate * 10).rounded() / 10,
                        firstAudioMS: firstAudioAt.map { Int((($0 - startedAt) * 1000).rounded()) },
                        peakDBFS: peakDBFS,
                        audibleFraction: chunks == 0 ? 0 : (Double(audibleChunks) / Double(chunks) * 100).rounded() / 100,
                        partials: partials, transcripts: transcripts,
                        textLatencyMeanMS: latencyCount == 0 ? nil : Int((latencySum / Double(latencyCount) * 1000).rounded()),
                        textLatencyMaxMS: latencyCount == 0 ? nil : Int((latencyMax * 1000).rounded()))
    }
}

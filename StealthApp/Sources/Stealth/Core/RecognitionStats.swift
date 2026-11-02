import Foundation

/// Content-free recognition timing a speech provider keeps for diagnostics.
///
/// Final lag is measured on the audio timeline: how much audio had been captured after an
/// utterance's end when its final text arrived. It therefore includes endpoint silence,
/// queueing and inference, but not capture-callback buffering, and assumes capture was
/// continuous in between. Stop-time flushes are not counted.
struct RecognitionStats: Equatable {
    /// Largest captured audio a provider may hold for its recognizer, before or after it is ready.
    static let maximumBacklogMS = 12_000

    /// From `connect` to the recognizer reporting ready (model load and warm-up).
    var readyMS: Int?
    /// Largest captured audio waiting for the recognizer.
    var backlogMaxMS = 0
    var finalLagCount = 0
    var finalLagSumMS = 0
    var finalLagMaxMS = 0
    var failure: CaptureDiagnostics.Failure?

    var finalLagMeanMS: Int? { finalLagCount == 0 ? nil : finalLagSumMS / finalLagCount }

    mutating func noteBacklog(ms: Int) { backlogMaxMS = max(backlogMaxMS, ms) }
    /// `capturedMS` and `endMS` share the provider's audio timeline, starting at its first sample.
    mutating func noteFinal(capturedMS: Int, endMS: Int) {
        let lag = max(0, capturedMS - endMS)
        finalLagCount += 1; finalLagSumMS += lag; finalLagMaxMS = max(finalLagMaxMS, lag)
    }
    /// Overflow before the recognizer is ready means a slow load, not slow inference.
    static func overflowFailure(ready: Bool) -> CaptureDiagnostics.Failure { ready ? .speech_behind : .speech_load_slow }
}

@MainActor protocol RecognitionStatsReporting: AnyObject {
    var recognitionStats: RecognitionStats { get }
}

/// Audio handed to a FIFO recognizer input that is consumed on its own task, but not yet taken.
/// Bounds the queue by duration instead of buffer count, whose size depends on the device.
final class AudioBacklog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Double] = []
    private var outstandingMS = 0.0
    /// Returns the outstanding duration including `ms`.
    func add(_ ms: Double) -> Double { lock.withLock { items.append(ms); outstandingMS += ms; return outstandingMS } }
    /// The recognizer took the oldest input.
    func removeOldest() {
        lock.withLock {
            guard !items.isEmpty else { return }
            outstandingMS = max(0, outstandingMS - items.removeFirst())
        }
    }
}

import Foundation

/// Bounded, sample-clock endpoint detector for Apple ASR. It requests ASR
/// finalization only; it never decides whether a transcript is a question.
/// 20ms windows make behavior independent of capture/IPC packet sizes.
struct PCMEndpoint {
    private(set) var speaking = false
    private(set) var frames: Int64 = 0
    private var window: [Int16] = []
    private var voicedFrames = 0
    private var quietFrames = 0
    private var noiseRMS = 80.0
    private let quietLimit = 12_000 // 750ms, includes time consumed by ASR.
    enum Event: Equatable { case started, ended(frame: Int64) }
    mutating func consume(_ data: Data) -> [Event] {
        var events: [Event] = []
        data.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: bytes.count - 1, by: 2) {
                window.append(bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self).littleEndian)
                frames += 1
                guard window.count == 320 else { continue }
                let rms = sqrt(window.reduce(0.0) { $0 + Double($1) * Double($1) } / 320)
                let voiced = rms > max(180, min(900, noiseRMS * 3.5))
                if !speaking && !voiced { noiseRMS = noiseRMS * 0.95 + rms * 0.05 }
                window.removeAll(keepingCapacity: true)
                if voiced {
                    voicedFrames += 320; quietFrames = 0
                    if !speaking && voicedFrames >= 960 { speaking = true; events.append(.started) }
                } else {
                    voicedFrames = 0
                    if speaking {
                        quietFrames += 320
                        if quietFrames >= quietLimit {
                            speaking = false; quietFrames = 0
                            events.append(.ended(frame: frames))
                        }
                    }
                }
            }
        }
        return events
    }
}

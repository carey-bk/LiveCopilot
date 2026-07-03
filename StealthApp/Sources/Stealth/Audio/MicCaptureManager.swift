import Foundation
import AVFoundation
import OSLog

/// Captures YOUR microphone and delivers 24 kHz mono PCM16 chunks,
/// matching the format the Realtime API expects (same as system audio).
///
/// Uses AVAudioEngine's input node tap → AVAudioConverter to the target format.
@MainActor
final class MicCaptureManager: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var lastError: String?

    /// Called on the audio thread with PCM16 mono 24kHz chunks.
    var onPCM16: ((Data) -> Void)?

    private let log = Logger(subsystem: "com.stealth.app", category: "mic")
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var bufferCount = 0

    private lazy var targetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Config.realtimeSampleRate,
            channels: 1,
            interleaved: true
        )!
    }()

    func start() {
        guard !isCapturing else { return }
        lastError = nil

        let input = engine.inputNode

        // Apple's voice processing (acoustic echo cancellation + noise suppression)
        // subtracts speaker bleed so it isn't mislabeled "You" — but it can also
        // over-suppress the user's own voice, leaving the "You" side silent. Gated by
        // Config so we can isolate that. NOTE: enabling changes the input format, so
        // read the format AFTER.
        if Config.micEchoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
                DebugLog.log("MIC voice processing (AEC) enabled")
            } catch {
                DebugLog.log("MIC AEC enable failed (continuing without): \(error.localizedDescription)")
            }
        } else {
            DebugLog.log("MIC voice processing (AEC) DISABLED (Config.micEchoCancellation=false)")
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            lastError = "No microphone input available."
            DebugLog.log("MIC no input format")
            return
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndEmit(buffer, from: inputFormat)
        }

        do {
            engine.prepare()
            try engine.start()
            isCapturing = true
            DebugLog.log("MIC capture started OK (input \(inputFormat.sampleRate)Hz)")
        } catch {
            lastError = error.localizedDescription
            DebugLog.log("MIC capture FAILED: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isCapturing = false
        DebugLog.log("MIC capture stopped")
    }

    private func convertAndEmit(_ buffer: AVAudioPCMBuffer, from inputFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }

        let frames = Int(out.frameLength)
        let bytes = frames * MemoryLayout<Int16>.size
        let data = Data(bytes: ch[0], count: bytes)
        bufferCount += 1
        if bufferCount % 25 == 1 {
            // Audio level (RMS + peak) so we can tell silence/over-suppression
            // (near 0) from a healthy signal that simply isn't tripping VAD.
            var sumSq = 0.0
            var peak: Int16 = 0
            for i in 0..<frames {
                let s = ch[0][i]
                sumSq += Double(s) * Double(s)
                let a = s == Int16.min ? Int16.max : abs(s)
                if a > peak { peak = a }
            }
            let rms = frames > 0 ? Int(sqrt(sumSq / Double(frames))) : 0
            DebugLog.log("MIC pcm #\(bufferCount) — \(bytes)B rms=\(rms) peak=\(peak) (max 32767)")
        }
        onPCM16?(data)
    }
}

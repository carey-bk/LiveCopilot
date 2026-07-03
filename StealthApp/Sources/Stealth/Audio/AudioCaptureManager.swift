import Foundation
import ScreenCaptureKit
import AVFoundation
import OSLog

/// Captures SYSTEM audio (everyone else on the call — browser Meet, Zoom, Teams, anything)
/// via ScreenCaptureKit, with no microphone and no virtual audio device.
///
/// Output is delivered as 24 kHz mono PCM16 little-endian `Data`, ready for the Realtime API.
@MainActor
final class AudioCaptureManager: NSObject, ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var lastError: String?

    /// Called on a background queue with PCM16 mono 24kHz audio chunks.
    var onPCM16: ((Data) -> Void)?

    private let log = Logger(subsystem: "com.stealth.app", category: "audio")
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var pcmBufferCount = 0
    private let outputQueue = DispatchQueue(label: "com.stealth.audio.output")

    private lazy var targetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Config.realtimeSampleRate,
            channels: 1,
            interleaved: true
        )!
    }()

    func start() async {
        guard !isCapturing else { return }
        lastError = nil
        do {
            // Pick the main display as the capture surface. We discard video frames;
            // ScreenCaptureKit still requires a content filter built from shareable content.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else {
                throw CaptureError.noDisplay
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])

            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true          // never capture our own sounds
            cfg.sampleRate = Int(Config.realtimeSampleRate)
            cfg.channelCount = 1
            // Minimise video work — we only want audio.
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.queueDepth = 6

            let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()

            self.stream = stream
            self.isCapturing = true
            log.info("System audio capture started")
            DebugLog.log("AUDIO capture started OK")
        } catch {
            lastError = humanReadable(error)
            log.error("Capture start failed: \(error.localizedDescription, privacy: .public)")
            DebugLog.log("AUDIO capture FAILED: \(error.localizedDescription)")
        }
    }

    func stop() async {
        guard let stream else { return }
        do { try await stream.stopCapture() } catch {
            log.error("Stop failed: \(error.localizedDescription, privacy: .public)")
        }
        self.stream = nil
        self.converter = nil
        self.isCapturing = false
        log.info("System audio capture stopped")
    }

    // MARK: - Conversion

    /// Convert an incoming sample buffer (Float32, device-rate) to 24kHz mono PCM16.
    fileprivate func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }

        // Build / reuse a converter matching the actual input format.
        if converter == nil || converter?.inputFormat != pcmBuffer.format {
            converter = AVAudioConverter(from: pcmBuffer.format, to: targetFormat)
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / pcmBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: capacity
        ) else { return }

        var fed = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }

        if status == .error || convError != nil {
            log.error("Audio convert error: \(convError?.localizedDescription ?? "?", privacy: .public)")
            return
        }
        guard outBuffer.frameLength > 0,
              let channel = outBuffer.int16ChannelData
        else { return }

        let byteCount = Int(outBuffer.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: channel[0], count: byteCount)
        pcmBufferCount += 1
        if pcmBufferCount % 100 == 1 {
            DebugLog.log("AUDIO pcm buffer #\(pcmBufferCount) — \(byteCount) bytes @ \(targetFormat.sampleRate)Hz")
        }
        onPCM16?(data)
    }

    private func humanReadable(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == SCStreamError.errorDomain {
            return "Screen Recording permission is required. Grant it in System Settings → Privacy & Security → Screen Recording, then reopen Stealth."
        }
        return error.localizedDescription
    }

    enum CaptureError: Error { case noDisplay }
}

// MARK: - SCStream callbacks

extension AudioCaptureManager: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.lastError = self.humanReadable(error)
            self.isCapturing = false
        }
    }
}

extension AudioCaptureManager: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        Task { @MainActor in self.handleAudio(sampleBuffer) }
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

private extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }

        let format = AVAudioFormat(streamDescription: asbd)
        guard let format else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        return status == noErr ? pcmBuffer : nil
    }
}

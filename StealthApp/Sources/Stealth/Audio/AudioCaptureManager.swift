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

    private let log = Logger(subsystem: "com.livecopilot.app", category: "audio")
    private var stream: SCStream?
    private var output: AudioStreamOutput?
    private var pcmBufferCount = 0
    private let outputQueue = DispatchQueue(label: "com.livecopilot.audio.output")

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
            let output = AudioStreamOutput(emit: onPCM16)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: outputQueue)
            self.output = output
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
        self.output = nil
        self.isCapturing = false
        log.info("System audio capture stopped")
    }

    private func humanReadable(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == SCStreamError.errorDomain {
            return "Screen Recording permission is required. Grant it in System Settings → Privacy & Security → Screen Recording, then reopen LiveCopilot."
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

private final class AudioStreamOutput: NSObject, SCStreamOutput {
    private let converter = PCMConverter()
    private let emit: ((Data) -> Void)?
    init(emit: ((Data) -> Void)?) { self.emit = emit }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = sampleBuffer.toPCMBuffer(),
              let data = converter.convert(buffer) else { return }
        emit?(data)
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

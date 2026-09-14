import Foundation
@preconcurrency import AVFoundation

/// An independent converter per input. Serializes converter state with stop/reset, and runs
/// synchronously on the capture callback queue, never by mutating a MainActor UI object.
final class PCMConverter: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    func configure(sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        converter = nil
    }
    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard buffer.format.sampleRate > 0, buffer.frameLength > 0 else { return nil }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: target) }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(output.frameLength) * 2)
    }
    func reset() { lock.lock(); converter = nil; lock.unlock() }
}

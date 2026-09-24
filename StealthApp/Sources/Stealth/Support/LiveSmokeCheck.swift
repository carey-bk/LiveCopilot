import Foundation
import AVFoundation

/// Explicit opt-in API verification, using a supplied synthetic file or silence.
/// Does not acquire a microphone or system-audio capture permission.
enum LiveSmokeCheck {
    @MainActor static func run(key: String, settings: AppSettings, audioURL: URL?, report: (String) -> Void) async throws {
        let live = OpenAILiveProvider(key: key, model: settings.liveModel, speaker: .them, scenario: .meeting, language: settings.liveSpeechLanguage)
        var ready = false, failure: String?, delegated = false, transcript = "", closed = false
        live.onEvent = { event in
            switch event {
            case .ready: ready = true
            case .failed(let message): failure = message
            case .transcript(let fragment): transcript += fragment.text
            case .delegation: delegated = true
            case .closed(let finalized): closed = finalized
            default: break
            }
        }
        do {
        live.connect(context: "This is an automated synthetic audio check. Delegate the benchmark question when complete.")
        let deadline = Date().addingTimeInterval(25)
        while !ready && failure == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard ready else { await live.disconnect(); throw CopilotError.message(failure ?? "Live did not start before timeout.") }
        report("PASS official GPT-Live session.started")
        if let audioURL {
            let file = try AVAudioFile(forReading: audioURL)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                await live.disconnect(); throw CopilotError.message("Cannot decode synthetic audio.")
            }
            try file.read(into: buffer)
            guard let data = PCMConverter().convert(buffer) else { await live.disconnect(); throw CopilotError.message("Cannot convert synthetic audio.") }
            for start in stride(from: 0, to: data.count, by: 4800) {
                live.sendAudio(data.subdata(in: start..<min(start + 4800, data.count)))
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            for _ in 0..<120 {
                live.sendAudio(Data(repeating: 0, count: 4800))
                try await Task.sleep(nanoseconds: 100_000_000)
                if delegated && !transcript.isEmpty { break }
            }
        } else {
            for _ in 0..<10 { live.sendAudio(Data(repeating: 0, count: 4800)); try await Task.sleep(nanoseconds: 100_000_000) }
        }
        await live.disconnect()
        guard closed else { throw CopilotError.message("Live disconnected without session.closed; final duration unconfirmed.") }
        report("PASS official Live session.closed")
        if audioURL != nil {
            let scalars = transcript.unicodeScalars.map { Int($0.value) }
            let han = scalars.filter { (0x3400...0x9FFF).contains($0) }.count
            let hangul = scalars.filter { (0xAC00...0xD7AF).contains($0) || (0x1100...0x11FF).contains($0) || (0x3130...0x318F).contains($0) }.count
            let latin = scalars.filter { (65...90).contains($0) || (97...122).contains($0) }.count
            report("Synthetic caption script counts: Han=\(han), Latin=\(latin), Hangul=\(hangul). Transcript text withheld.")
            guard delegated, !transcript.isEmpty else { throw CopilotError.message("Live connected but synthetic question transcription/delegation was not observed (transcript=\(!transcript.isEmpty), delegated=\(delegated)).") }
            report("PASS synthetic speech transcription and semantic client delegation")
        }
        } catch {
            await live.disconnect()
            throw error
        }
    }
}

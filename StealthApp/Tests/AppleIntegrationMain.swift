import Foundation
import AVFoundation

/// Synthetic fixtures only. No microphone, system capture, credentials or cloud API.
@main struct AppleIntegrationMain {
    @MainActor static func main() async {
        do { try await run() } catch { print("FAIL \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        setbuf(stdout, nil)
        guard #available(macOS 26, *), AppleSpeechSupport.available else { throw CopilotError.message("Apple speech unavailable") }
        guard CommandLine.arguments.count == 2 else { throw CopilotError.message("Usage: AppleChecks <fixture-directory>") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        for (name, language, speaker) in [("en", AppleSpeechLanguage.english, Speaker.them), ("zh", .chinese, .room), ("own", .english, .you)] {
            if ProcessInfo.processInfo.environment["APPLE_ASR_INSTALL"] == "1" { try await AppleSpeechSupport.install(language) }
            guard await AppleSpeechSupport.installed(language) else { throw CopilotError.message("Download Apple language in app first") }
            let file = try AVAudioFile(forReading: root.appendingPathComponent(name + ".aiff"))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let converter = PCMConverter(); converter.configure(sampleRate: 16000)
            var pcm = Data(repeating: 0, count: 16000); pcm.append(converter.convert(buffer)!)
            let speechEndMS = pcm.count / 32
            pcm.append(Data(repeating: 0, count: 32000 * 3))
            let provider = AppleLiveProvider(speaker: speaker, language: language)
            var transcript = "", finalIDs = Set<String>(), previews = Set<String>(), preview = "", failure: String?
            var firstMS: Int?, firstFinalMS: Int?, sent = 0, triggers = 0, ready = false, closed = false, premature = false
            provider.onEvent = { event in
                switch event {
                case .ready: ready = true
                case .transcript(let fragment):
                    if !finalIDs.insert(fragment.id).inserted { failure = "Duplicate final" }
                    transcript += fragment.text; if firstFinalMS == nil { firstFinalMS = sent / 32 }
                case .partialTranscript(let text):
                    preview = text
                    if !text.isEmpty { previews.insert(text); if firstMS == nil { firstMS = sent / 32 } }
                case .delegation: triggers += 1; premature = premature || transcript.isEmpty || !preview.isEmpty
                case .failed(let message): failure = message
                case .closed(let finalized): closed = finalized
                default: break
                }
            }
            let started = Date(); try await provider.prepare(); let loaded = Date()
            provider.connect(context: "")
            let deadline = Date().addingTimeInterval(15)
            while !ready && failure == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard ready else { await provider.disconnect(); throw CopilotError.message("Apple startup did not become ready") }
            for offset in stride(from: 0, to: pcm.count, by: 8000) {
                sent = min(pcm.count, offset + 8000)
                provider.sendAudio(pcm.subdata(in: offset..<sent))
                try await Task.sleep(for: .milliseconds(250))
            }
            try await Task.sleep(for: .milliseconds(1400))
            await provider.disconnect()
            print("Apple \(name): load_ms=\(Int(loaded.timeIntervalSince(started)*1000)), first_preview_audio_ms=\(firstMS ?? -1), first_final_audio_ms=\(firstFinalMS ?? -1), speech_end_ms=\(speechEndMS), previews=\(previews.count), finals=\(finalIDs.count), triggers=\(triggers), closed=\(closed), failure=\(failure ?? "none"); synthetic transcript: \(transcript)")
            guard failure == nil, closed, !premature, preview.isEmpty, !transcript.isEmpty,
                  previews.count >= 2, let firstMS, firstMS < speechEndMS,
                  triggers == (speaker == .you ? 0 : 1) else { throw CopilotError.message("Apple streaming/trigger acceptance failed") }
        }
        for silenceOnly in [false, true] {
            let provider = AppleLiveProvider(speaker: .you, language: .english)
            var result = "", complete = false, error: String?
            provider.onEvent = { event in
                switch event {
                case .transcript(let fragment): result += fragment.text
                case .closed(let finalized): complete = finalized
                case .failed(let message): error = message
                default: break
                }
            }
            try await provider.prepare(); provider.connect(context: "")
            var pcm = Data(repeating: 0, count: 32000 * 3)
            if !silenceOnly {
                let file = try AVAudioFile(forReading: root.appendingPathComponent("en.aiff"))
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: buffer)
                let converter = PCMConverter(); converter.configure(sampleRate: 16000)
                pcm = converter.convert(buffer)!
            }
            try await Task.sleep(for: .milliseconds(50))
            for offset in stride(from: 0, to: pcm.count, by: 8000) {
                provider.sendAudio(pcm.subdata(in: offset..<min(pcm.count, offset + 8000)))
            }
            await provider.disconnect()
            guard complete, error == nil, silenceOnly ? result.isEmpty : result.lowercased().contains("latency") else {
                throw CopilotError.message("Apple silence/stop flush failed")
            }
            print("PASS Apple \(silenceOnly ? "silence suppression" : "stop without trailing silence preserves final word")")
        }
        let early = AppleLiveProvider(speaker: .you, language: .english)
        early.connect(context: ""); await early.disconnect()
        print("PASS Apple Chinese/English streaming, source-specific question triggers, final drain and immediate stop. No cloud calls.")
    }
}

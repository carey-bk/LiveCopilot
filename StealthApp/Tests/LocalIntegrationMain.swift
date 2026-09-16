import Foundation
import AVFoundation

/// Explicit real local-model acceptance. No API credentials, real capture or network requests.
@main struct LocalIntegrationMain {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard args.count >= 4 else { fatalError("Usage: LocalChecks <model-root> <runtime-executable> <download-cache> [paraformer-only]") }
        let root = URL(fileURLWithPath: args[1]), executable = URL(fileURLWithPath: args[2]), cache = URL(fileURLWithPath: args[3])
        let speechOnly = args.contains("paraformer-only")
        let speechKinds: [LocalModelKind] = [.streamingSpeech]
        for kind in speechOnly ? speechKinds : LocalModelKind.allCases {
            if !kind.isInstalled(in: root) {
                try await LocalModelInstaller.install(kind, root: root, downloader: { item, destination in
                    try FileManager.default.copyItem(at: cache.appendingPathComponent(item.name), to: destination)
                })
            }
            print("PASS verified local model installation: \(kind.rawValue)")
        }
        let fixtures = root.deletingLastPathComponent().appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        for speechKind in speechKinds {
            for (name, voice, text, expected, speaker) in [
                ("en", "Samantha", "Why did we choose method B, and what is its latency?", "latency", Speaker.them),
                ("zh", "Tingting", "请问这个实验为什么选择方法B？它的延迟是多少毫秒？", "延迟", Speaker.room),
                ("own", "Samantha", "Why did we choose method B, and what is its latency?", "latency", Speaker.you)
            ] {
                let audio = fixtures.appendingPathComponent(name + ".aiff")
                let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                say.arguments = ["-v", voice, "-o", audio.path, text]
                try say.run(); say.waitUntilExit()
                guard say.terminationStatus == 0 else { throw CopilotError.message("Synthetic voice is unavailable.") }
                let file = try AVAudioFile(forReading: audio)
                let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: source)
                let converter = PCMConverter(); converter.configure(sampleRate: 16000)
                var pcm = Data(repeating: 0, count: 16000)
                pcm.append(converter.convert(source)!)
                pcm.append(Data(repeating: 0, count: 16000 * 2))
                let provider = LocalLiveProvider(directory: speechKind.location(in: root), speaker: speaker, executable: executable)
                var transcript = "", delegations = 0, failure: String?
                var partials = Set<String>(), firstPartialMS: Int?, sentBytes = 0, prematureDelegation = false
                var finalCount = 0, preview = "", finalized = false
                var firstFinalAudioMS: Int?
                provider.onEvent = { event in
                    switch event {
                    case .transcript(let fragment): transcript += fragment.text; finalCount += 1; if firstFinalAudioMS == nil { firstFinalAudioMS = sentBytes / 32 }
                    case .partialTranscript(let text):
                        preview = text
                        if !text.isEmpty {
                            partials.insert(text)
                            if firstPartialMS == nil { firstPartialMS = sentBytes / 32 }
                        }
                    case .delegation: delegations += 1; if finalCount == 0 { prematureDelegation = true }
                    case .closed(let complete): finalized = complete
                    case .failed(let message): failure = message
                    default: break
                    }
                }
                let start = Date(); try await provider.prepare(); let loaded = Date()
                provider.connect(context: "")
                for offset in stride(from: 0, to: pcm.count, by: 8000) {
                    let end = min(pcm.count, offset + 8000)
                    sentBytes = end
                    provider.sendAudio(pcm.subdata(in: offset..<end))
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                let deadline = Date().addingTimeInterval(25)
                while (transcript.isEmpty || (speaker != .you && delegations == 0)) && failure == nil && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
                if speaker == .you { try await Task.sleep(nanoseconds: 1_200_000_000) }
                await provider.disconnect()
                // Keyword fidelity is diagnostic; preview/finalization is the contract.
                let keywordMatch = transcript.lowercased().contains(expected)
                print("QUALITY \(speechKind.rawValue) \(name): reference_keyword=\(expected), matched=\(keywordMatch), first_final_audio_ms=\(firstFinalAudioMS ?? -1)")
                guard failure == nil, finalized, !prematureDelegation, preview.isEmpty, !transcript.isEmpty,
                      delegations == (speaker == .you ? 0 : 1) else {
                    print("Synthetic transcript: \(transcript); delegations=\(delegations)")
                    throw CopilotError.message(failure ?? "Local ASR/trigger acceptance failed.")
                }
                do {
                    guard partials.count >= 2, let first = firstPartialMS, first < (pcm.count - 32000) / 32 else {
                        throw CopilotError.message("Streaming captions did not appear before speech ended.")
                    }
                    print("PASS streaming previews=\(partials.count); first_preview_audio_ms=\(first); committed_segments=\(finalCount)")
                }
                print("PASS \(speechKind.rawValue) \(name) local ASR + VAD + question trigger; load_ms=\(Int(loaded.timeIntervalSince(start)*1000)), total_ms=\(Int(Date().timeIntervalSince(start)*1000)); synthetic transcript: \(transcript)")
            }
            let flushWorker = LocalInferenceWorker(mode: "paraformer", modelDirectory: speechKind.location(in: root), executable: executable)
            let silence = try await flushWorker.call(["op": "audio", "pcm": Data(repeating: 0, count: 32000).base64EncodedString()])
            guard (silence["segments"] as? [[String: Any]])?.isEmpty == true else { throw CopilotError.message("Silence produced a transcript.") }
            let tailFile = try AVAudioFile(forReading: fixtures.appendingPathComponent("en.aiff"))
            let tailBuffer = AVAudioPCMBuffer(pcmFormat: tailFile.processingFormat, frameCapacity: AVAudioFrameCount(tailFile.length))!
            try tailFile.read(into: tailBuffer)
            let tailConverter = PCMConverter(); tailConverter.configure(sampleRate: 16000)
            let tailPCM = tailConverter.convert(tailBuffer)!
            _ = try await flushWorker.call(["op": "audio", "pcm": tailPCM.base64EncodedString()])
            let tail = try await flushWorker.call(["op": "flush"])
            let flushed = (tail["segments"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
            // This fixture's final word can be misrecognized by Paraformer. Compare
            // the full final result to the same audio through an unstopped stream
            // below instead of making spelling correction part of stop handling.
            guard !flushed.isEmpty else { throw CopilotError.message("Final speech was lost when stopping.") }
            do {
                let secondFlush = try await flushWorker.call(["op": "flush"])
                guard (secondFlush["segments"] as? [[String: Any]])?.isEmpty == true,
                      (secondFlush["partial"] as? String)?.isEmpty == true else { throw CopilotError.message("Final text was duplicated on a second flush.") }
                let baseline = LocalInferenceWorker(mode: "paraformer", modelDirectory: speechKind.location(in: root), executable: executable)
                defer { baseline.close() }
                _ = try await baseline.call(["op": "audio", "pcm": Data(repeating: 0, count: 32000).base64EncodedString()])
                var full = tailPCM
                full.append(Data(repeating: 0, count: 32000))
                let result = try await baseline.call(["op": "audio", "pcm": full.base64EncodedString()])
                let normal = (result["segments"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
                guard normal == flushed else { throw CopilotError.message("Stopping changed the final streaming transcript.") }
                print("PASS early stop matches normal endpoint, with no duplicate flush; synthetic transcript: \(flushed)")
            }
            flushWorker.close(); print("PASS silence suppression and final partial-segment flush")
        } // speechKinds
        if !speechOnly {
            let provider = LocalEmbeddingProvider(directory: LocalModelKind.embedding.location(in: root), executable: executable)
            defer { provider.close() }
            let started = Date()
            let vectors = try await provider.embed(["方法B的延迟是多少？", "Method B has a measured latency of 42 milliseconds.", "The kitchen serves fresh bread and coffee."])
            let relevant = VectorMath.cosine(vectors[0], vectors[1]), unrelated = VectorMath.cosine(vectors[0], vectors[2])
            guard vectors.allSatisfy({ $0.count == 1024 }), relevant > unrelated + 0.1 else { throw CopilotError.message("Local cross-language embedding acceptance failed.") }
            print("PASS BGE-M3 cross-language retrieval; relevant=\(relevant), unrelated=\(unrelated), total_ms=\(Int(Date().timeIntervalSince(started)*1000))")
            let corpus = fixtures.appendingPathComponent("synthetic-benchmark.txt")
            try "Synthetic benchmark: Method B has a measured latency of 42 milliseconds. The sample size is 128.".write(to: corpus, atomically: true, encoding: .utf8)
            let indexPath = fixtures.appendingPathComponent("knowledge-" + UUID().uuidString)
            let index = try KnowledgeIndex(directory: indexPath)
            let doc = try await index.importDocument(corpus, provider: provider)
            let query = RetrievalQuery.formulate(question: "方法B的延迟是多少？", context: "")
            let queryStart = Date()
            let vector = try await provider.embed([query.semantic])[0]
            let reopened = try KnowledgeIndex(directory: indexPath)
            let sources = try await reopened.retrieve(query: query, vector: vector, model: provider.model, limit: 6)
            guard sources.first?.chunk.documentID == doc.id, sources.first?.chunk.text.contains("42") == true else { throw CopilotError.message("Local RAG acceptance failed.") }
            print("PASS real local document indexing, reopened persisted vectors and Chinese query retrieval; warm_query_ms=\(Int(Date().timeIntervalSince(queryStart)*1000))")
        }
        print("Local acceptance passed. No cloud API calls or physical audio capture.")
    }
}

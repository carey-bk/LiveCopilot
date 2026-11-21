// Native, persistent inference worker. Only JSON replies go to stdout. No network APIs.
#import <Foundation/Foundation.h>
#include "sherpa-onnx/c-api/c-api.h"

#include <cmath>
#include <csignal>
#include <iostream>
#include <memory>
#include <new>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <thread>
#include <vector>

static int asrThreadCount() {
    const unsigned int hw = std::thread::hardware_concurrency();
#if defined(__x86_64__)
    // Leave CPU headroom on older Intel Macs so foreground video conferencing (e.g. Teams) is not starved.
    (void)hw;
    return 1;
#else
    return (hw > 0 && hw <= 4) ? 1 : 2;
#endif
}

static void reply(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!data) throw std::runtime_error("json");
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
}

// Streaming Paraformer keeps encoder/decoder caches across live audio chunks.
// Silero gates silence and finalizes utterances; previews never become final by
// merely being displayed. Fresh streams bound memory and prevent cross-turn repeats.
class StreamingSpeechEngine {
    const SherpaOnnxOnlineRecognizer *recognizer = nullptr;
    const SherpaOnnxOnlineStream *stream = nullptr;
    const SherpaOnnxVoiceActivityDetector *vad = nullptr;
    std::vector<float> pending, preRoll;
    int64_t processed = 0, received = 0, streamStart = 0;
    bool contextual = false;
    std::string nextHotwords;
public:
    explicit StreamingSpeechEngine(const std::string &root, bool useHotwords = false) : contextual(useHotwords) {
        const auto encoder = root + "/encoder.int8.onnx", decoder = root + (contextual ? "/decoder.onnx" : "/decoder.int8.onnx");
        const auto tokens = root + "/tokens.txt", vadPath = root + "/silero_vad.onnx";
        SherpaOnnxOnlineRecognizerConfig config{};
        config.feat_config.sample_rate = 16000; config.feat_config.feature_dim = 80;
        config.decoding_method = contextual ? "modified_beam_search" : "greedy_search";
        config.max_active_paths = 4;
        // Dynamic Zipformer terms need enough weight to retain competing spellings.
        // On the same audio, 3 recovers 启衡系统; widening the beam gave no further gain.
        config.hotwords_score = 3.0f;
        config.model_config.num_threads = asrThreadCount(); config.model_config.provider = "cpu";
        config.model_config.tokens = tokens.c_str();
        const auto joiner = root + "/joiner.int8.onnx", bpe = root + "/bpe.vocab";
        if (contextual) {
            config.model_config.transducer.encoder = encoder.c_str();
            config.model_config.transducer.decoder = decoder.c_str();
            config.model_config.transducer.joiner = joiner.c_str();
            config.model_config.modeling_unit = "cjkchar+bpe";
            config.model_config.bpe_vocab = bpe.c_str();
        } else {
            config.model_config.paraformer.encoder = encoder.c_str();
            config.model_config.paraformer.decoder = decoder.c_str();
        }
        recognizer = SherpaOnnxCreateOnlineRecognizer(&config);
        if (!recognizer) throw std::runtime_error("streaming_asr_load");
        SherpaOnnxVadModelConfig v{};
        v.silero_vad.model = vadPath.c_str(); v.silero_vad.threshold = 0.5f;
        v.silero_vad.min_silence_duration = 0.65f; v.silero_vad.min_speech_duration = 0.2f;
        v.silero_vad.max_speech_duration = 12.0f; v.silero_vad.window_size = 512;
        v.sample_rate = 16000; v.num_threads = 1; v.provider = "cpu";
        vad = SherpaOnnxCreateVoiceActivityDetector(&v, 30);
        if (!vad) { SherpaOnnxDestroyOnlineRecognizer(recognizer); recognizer = nullptr; throw std::runtime_error("vad_load"); }
    }
    ~StreamingSpeechEngine() {
        if (stream) SherpaOnnxDestroyOnlineStream(stream);
        if (vad) SherpaOnnxDestroyVoiceActivityDetector(vad);
        if (recognizer) SherpaOnnxDestroyOnlineRecognizer(recognizer);
    }
    void setTerms(NSArray *terms) {
        if (!contextual || terms.count > 100) throw std::runtime_error("hotwords_unsupported_or_limit");
        std::string updated;
        for (id item in terms) {
            if (![item isKindOfClass:NSString.class] || [item length] > 100) throw std::runtime_error("hotword_invalid");
            if ([item rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\n\r:#"]].location != NSNotFound)
                throw std::runtime_error("hotword_invalid");
            if (!updated.empty()) updated += "\n";
            updated += [[item uppercaseString] UTF8String];
        }
        // Only newly created utterances receive this snapshot.
        nextHotwords = std::move(updated);
    }
    void decode() {
        while (SherpaOnnxIsOnlineStreamReady(recognizer, stream)) SherpaOnnxDecodeOnlineStream(recognizer, stream);
    }
    NSString *text() {
        if (!stream) return @"";
        const auto *result = SherpaOnnxGetOnlineStreamResult(recognizer, stream);
        NSString *value = result && result->text ? [NSString stringWithUTF8String:result->text] : @"";
        if (result) SherpaOnnxDestroyOnlineRecognizerResult(result);
        return value ?: @"";
    }
    void finalize(NSMutableArray *segments, int64_t end) {
        if (!stream) return;
        // The final chunk can be shorter than the normal model chunk. Preserve
        // its decoder output even when the user stops without trailing silence.
        // Supply a full chunk plus lookahead. 300 ms alone truncates the final
        // token with this export when Stop arrives without natural silence.
        // This is generated padding, not a wall-clock wait or extra recording.
        const float tail[16000] = {};
        SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, tail, 16000);
        SherpaOnnxOnlineStreamSetOption(stream, "is_final", "1");
        SherpaOnnxOnlineStreamInputFinished(stream); decode();
        NSString *value = text();
        end = std::max(streamStart, std::min(received, end));
        if (value.length) [segments addObject:@{ @"text": value, @"start_ms": @(streamStart / 16), @"end_ms": @(end / 16) }];
        SherpaOnnxDestroyOnlineStream(stream); stream = nullptr; preRoll.clear();
    }
    void drain(NSMutableArray *segments) {
        while (!SherpaOnnxVoiceActivityDetectorEmpty(vad)) {
            const auto *segment = SherpaOnnxVoiceActivityDetectorFront(vad);
            if (!segment) throw std::runtime_error("vad_segment");
            const int64_t end = static_cast<int64_t>(segment->start) + segment->n;
            finalize(segments, end);
            SherpaOnnxDestroySpeechSegment(segment); SherpaOnnxVoiceActivityDetectorPop(vad);
        }
    }
    void window(const float *samples, NSMutableArray *segments) {
        processed += 512;
        SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, samples, 512);
        if (!stream) {
            preRoll.insert(preRoll.end(), samples, samples + 512);
            if (preRoll.size() > 8000) preRoll.erase(preRoll.begin(), preRoll.end() - 8000);
            if (SherpaOnnxVoiceActivityDetectorDetected(vad)) {
                stream = contextual && !nextHotwords.empty()
                    ? SherpaOnnxCreateOnlineStreamWithHotwords(recognizer, nextHotwords.c_str())
                    : SherpaOnnxCreateOnlineStream(recognizer);
                if (!stream) throw std::runtime_error("streaming_asr_stream");
                streamStart = processed - preRoll.size();
                SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, preRoll.data(), static_cast<int32_t>(preRoll.size()));
                preRoll.clear();
            }
        } else { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, samples, 512); }
        if (stream) decode();
        drain(segments);
    }
    NSDictionary *accept(NSData *pcm, bool flush) {
        if (pcm.length % 2 || pcm.length > 16000 * 2 * 15) throw std::runtime_error("audio_size");
        received += pcm.length / 2;
        const uint8_t *bytes = static_cast<const uint8_t *>(pcm.bytes);
        for (NSUInteger i = 0; i < pcm.length; i += 2) {
            int16_t sample = static_cast<int16_t>(static_cast<uint16_t>(bytes[i]) | (static_cast<uint16_t>(bytes[i + 1]) << 8));
            pending.push_back(static_cast<float>(sample) / 32768.0f);
        }
        NSMutableArray *segments = [NSMutableArray array];
        size_t consumed = 0;
        while (pending.size() - consumed >= 512) { window(pending.data() + consumed, segments); consumed += 512; }
        pending.erase(pending.begin(), pending.begin() + consumed);
        if (flush) {
            if (!pending.empty()) { pending.resize(512, 0); window(pending.data(), segments); pending.clear(); }
            SherpaOnnxVoiceActivityDetectorFlush(vad); drain(segments);
            finalize(segments, received);
        }
        return @{ @"segments": segments, @"partial": text(),
                  @"speaking": @(!flush && SherpaOnnxVoiceActivityDetectorDetected(vad) != 0) };
    }
};

#include "ArcticEngine.h"
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        signal(SIGPIPE, SIG_IGN);
        try {
            std::unique_ptr<StreamingSpeechEngine> streamingSpeech;
            std::unique_ptr<EmbeddingEngine> embedding;
            const std::string mode(argv[1]), root(argv[2]);
            // Run inference workers below foreground media priority so Teams/Zoom video decode/encode
            // threads preempt local CPU inference on constrained Intel/low-core Macs.
            const int niceValue = (mode == "embedding" || mode == "embedding-cpu") ? 12 : 10;
            (void)setpriority(PRIO_PROCESS, 0, niceValue);
            if (mode == "paraformer") streamingSpeech = std::make_unique<StreamingSpeechEngine>(root);
            else if (mode == "zipformer") streamingSpeech = std::make_unique<StreamingSpeechEngine>(root, true);
            else if (mode == "embedding" || mode == "embedding-cpu")
                embedding = std::make_unique<EmbeddingEngine>(root);
            else return 2;
            if (embedding) reply(@{ @"ready": @YES, @"protocol": @1, @"backend": @"ort-cpu", @"dim": @768, @"tokenizer_ms": @(embedding->tokenizerMs), @"session_ms": @(embedding->sessionMs) });
            else reply(@{ @"ready": @YES, @"protocol": @1 });
            std::string line;
            while (std::getline(std::cin, line)) {
                @autoreleasepool {
                    if (line.size() > 4 * 1024 * 1024) return 3;
                    NSData *data = [NSData dataWithBytes:line.data() length:line.size()];
                    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (![parsed isKindOfClass:NSDictionary.class]) return 3;
                    NSDictionary *command = parsed;
                    NSString *idValue = command[@"id"], *op = command[@"op"];
                    if (![idValue isKindOfClass:NSString.class] || ![op isKindOfClass:NSString.class]) return 3;
                    try {
                        NSMutableDictionary *response = [@{ @"id": idValue } mutableCopy];
                        if ([op isEqual:@"ping"]) response[@"ok"] = @YES;
                        else if (streamingSpeech && [op isEqual:@"terms"] && [command[@"terms"] isKindOfClass:NSArray.class]) {
                            streamingSpeech->setTerms(command[@"terms"]); response[@"ok"] = @YES;
                        } else if (streamingSpeech && ([op isEqual:@"audio"] || [op isEqual:@"flush"])) {
                            NSData *pcm = [op isEqual:@"flush"] ? [NSData data] : [[NSData alloc] initWithBase64EncodedString:command[@"pcm"] options:0];
                            if (!pcm) throw std::runtime_error("audio_base64");
                            [response addEntriesFromDictionary:streamingSpeech->accept(pcm, [op isEqual:@"flush"])];
                        } else if (embedding && [op isEqual:@"embed"]) {
                            response[@"vector"] = embedding->embed(command[@"text"],command[@"role"]);
                        } else throw std::runtime_error("operation");
                        reply(response);
                    } catch (const std::runtime_error &error) {
                        // Only fixed stage codes cross IPC; never input text, paths or native logs.
                        static NSSet<NSString *> *known = [NSSet setWithArray:@[
                            @"embedding_context", @"embedding_load", @"token_limit", @"text_size", @"embedding_decode",
                            @"embedding_dimension", @"embedding_finite", @"embedding_zero"]];
                        NSString *code = [NSString stringWithUTF8String:error.what()];
                        reply(@{ @"id": idValue, @"error": code && [known containsObject:code] ? code : @"inference_failed" });
                    } catch (const std::bad_alloc &) { reply(@{ @"id": idValue, @"error": @"embedding_decode" }); }
                    catch (...) { reply(@{ @"id": idValue, @"error": @"inference_failed" }); }
                }
            }
        } catch (const std::runtime_error &error) {
            // Only fixed stage codes cross IPC; never expose paths or model/input data.
            NSString *code = @"model_load_failed";
            if (strcmp(error.what(), "embedding_context") == 0) code = @"embedding_context";
            else if (strcmp(error.what(), "embedding_load") == 0) code = @"embedding_load";
            reply(@{ @"ready": @NO, @"error": code }); return 1;
        } catch (...) { reply(@{ @"ready": @NO, @"error": @"model_load_failed" }); return 1; }
    }
    return 0;
}

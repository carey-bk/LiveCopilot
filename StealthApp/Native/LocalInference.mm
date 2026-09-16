// Native, persistent inference worker. Only JSON replies go to stdout. No network APIs.
#import <Foundation/Foundation.h>
#include "sherpa-onnx/c-api/c-api.h"
#include "llama.h"
#include <cmath>
#include <csignal>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

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
public:
    explicit StreamingSpeechEngine(const std::string &root) {
        const auto encoder = root + "/encoder.int8.onnx", decoder = root + "/decoder.int8.onnx";
        const auto tokens = root + "/tokens.txt", vadPath = root + "/silero_vad.onnx";
        SherpaOnnxOnlineRecognizerConfig config{};
        config.feat_config.sample_rate = 16000; config.feat_config.feature_dim = 80;
        config.decoding_method = "greedy_search";
        config.model_config.num_threads = 2; config.model_config.provider = "cpu";
        config.model_config.tokens = tokens.c_str();
        config.model_config.paraformer.encoder = encoder.c_str();
        config.model_config.paraformer.decoder = decoder.c_str();
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
                stream = SherpaOnnxCreateOnlineStream(recognizer);
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

class EmbeddingEngine {
    llama_model *model = nullptr;
    llama_context *context = nullptr;
public:
    explicit EmbeddingEngine(const std::string &root) {
        llama_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
        llama_backend_init();
        auto m = llama_model_default_params(); m.n_gpu_layers = 99;
        model = llama_model_load_from_file((root + "/bge-m3-Q8_0.gguf").c_str(), m);
        if (!model) throw std::runtime_error("embedding_load");
        auto c = llama_context_default_params();
        c.n_ctx = 8192; c.n_batch = 8192; c.n_ubatch = 8192;
        c.embeddings = true; c.pooling_type = LLAMA_POOLING_TYPE_CLS;
        c.n_threads = 4; c.n_threads_batch = 4;
        context = llama_init_from_model(model, c);
        if (!context) { llama_model_free(model); model = nullptr; throw std::runtime_error("embedding_context"); }
    }
    ~EmbeddingEngine() {
        if (context) llama_free(context);
        if (model) llama_model_free(model);
        llama_backend_free();
    }
    NSArray *embed(NSString *text) {
        NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (!utf8.length || utf8.length > 100000) throw std::runtime_error("text_size");
        const auto *vocab = llama_model_get_vocab(model);
        std::vector<llama_token> tokens(utf8.length + 8);
        int count = llama_tokenize(vocab, static_cast<const char *>(utf8.bytes), static_cast<int>(utf8.length), tokens.data(), static_cast<int>(tokens.size()), true, false);
        if (count <= 0 || count > 8192) throw std::runtime_error("token_limit");
        auto batch = llama_batch_init(count, 0, 1); batch.n_tokens = count;
        for (int i = 0; i < count; ++i) {
            batch.token[i] = tokens[i]; batch.pos[i] = i; batch.n_seq_id[i] = 1;
            batch.seq_id[i][0] = 0; batch.logits[i] = true;
        }
        if (auto memory = llama_get_memory(context)) llama_memory_clear(memory, true);
        int status = llama_decode(context, batch); llama_batch_free(batch);
        if (status != 0) throw std::runtime_error("embedding_decode");
        const float *vector = llama_get_embeddings_seq(context, 0);
        const int dimension = llama_model_n_embd_out(model);
        if (!vector || dimension != 1024) throw std::runtime_error("embedding_dimension");
        double norm = 0;
        for (int i = 0; i < dimension; ++i) {
            if (!std::isfinite(vector[i])) throw std::runtime_error("embedding_finite");
            norm += static_cast<double>(vector[i]) * vector[i];
        }
        if (norm <= 0) throw std::runtime_error("embedding_zero");
        norm = std::sqrt(norm);
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:dimension];
        for (int i = 0; i < dimension; ++i) [result addObject:@(vector[i] / norm)];
        return result;
    }
};

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        signal(SIGPIPE, SIG_IGN);
        try {
            std::unique_ptr<StreamingSpeechEngine> streamingSpeech;
            std::unique_ptr<EmbeddingEngine> embedding;
            const std::string mode(argv[1]), root(argv[2]);
            if (mode == "paraformer") streamingSpeech = std::make_unique<StreamingSpeechEngine>(root);
            else if (mode == "embedding") embedding = std::make_unique<EmbeddingEngine>(root);
            else return 2;
            reply(@{ @"ready": @YES, @"protocol": @1 });
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
                        else if (streamingSpeech && ([op isEqual:@"audio"] || [op isEqual:@"flush"])) {
                            NSData *pcm = [op isEqual:@"flush"] ? [NSData data] : [[NSData alloc] initWithBase64EncodedString:command[@"pcm"] options:0];
                            if (!pcm) throw std::runtime_error("audio_base64");
                            [response addEntriesFromDictionary:streamingSpeech->accept(pcm, [op isEqual:@"flush"])];
                        } else if (embedding && [op isEqual:@"embed"] && [command[@"text"] isKindOfClass:NSString.class]) {
                            response[@"vector"] = embedding->embed(command[@"text"]);
                        } else throw std::runtime_error("operation");
                        reply(response);
                    } catch (...) { reply(@{ @"id": idValue, @"error": @"inference_failed" }); }
                }
            }
        } catch (...) { reply(@{ @"ready": @NO, @"error": @"model_load_failed" }); return 1; }
    }
    return 0;
}

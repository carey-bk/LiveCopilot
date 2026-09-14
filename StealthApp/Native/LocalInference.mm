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

class SpeechEngine {
    const SherpaOnnxOfflineRecognizer *recognizer = nullptr;
    const SherpaOnnxVoiceActivityDetector *vad = nullptr;
    std::vector<float> pending;
    std::vector<float> history;
    int64_t historyStart = 0, previousEnd = 0;
public:
    explicit SpeechEngine(const std::string &root) {
        const auto model = root + "/model.int8.onnx", tokens = root + "/tokens.txt", vadPath = root + "/silero_vad.onnx";
        SherpaOnnxOfflineRecognizerConfig config{};
        config.feat_config.sample_rate = 16000; config.feat_config.feature_dim = 80;
        config.decoding_method = "greedy_search";
        config.model_config.num_threads = 4; config.model_config.provider = "cpu";
        config.model_config.tokens = tokens.c_str();
        config.model_config.sense_voice.model = model.c_str();
        config.model_config.sense_voice.language = "auto"; config.model_config.sense_voice.use_itn = 1;
        recognizer = SherpaOnnxCreateOfflineRecognizer(&config);
        if (!recognizer) throw std::runtime_error("asr_load");
        SherpaOnnxVadModelConfig v{};
        v.silero_vad.model = vadPath.c_str(); v.silero_vad.threshold = 0.5f;
        v.silero_vad.min_silence_duration = 0.65f; v.silero_vad.min_speech_duration = 0.2f;
        v.silero_vad.max_speech_duration = 12.0f; v.silero_vad.window_size = 512;
        v.sample_rate = 16000; v.num_threads = 1; v.provider = "cpu";
        vad = SherpaOnnxCreateVoiceActivityDetector(&v, 30);
        if (!vad) { SherpaOnnxDestroyOfflineRecognizer(recognizer); recognizer = nullptr; throw std::runtime_error("vad_load"); }
    }
    ~SpeechEngine() {
        if (vad) SherpaOnnxDestroyVoiceActivityDetector(vad);
        if (recognizer) SherpaOnnxDestroyOfflineRecognizer(recognizer);
    }
    NSDictionary *accept(NSData *pcm, bool flush) {
        if (pcm.length % 2 || pcm.length > 16000 * 2 * 15) throw std::runtime_error("audio_size");
        const uint8_t *bytes = static_cast<const uint8_t *>(pcm.bytes);
        for (NSUInteger i = 0; i < pcm.length; i += 2) {
            int16_t sample = static_cast<int16_t>(static_cast<uint16_t>(bytes[i]) | (static_cast<uint16_t>(bytes[i + 1]) << 8));
            pending.push_back(static_cast<float>(sample) / 32768.0f);
            history.push_back(static_cast<float>(sample) / 32768.0f);
        }
        NSMutableArray *segments = [NSMutableArray array];
        size_t consumed = 0;
        while (pending.size() - consumed >= 512) {
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, pending.data() + consumed, 512);
            consumed += 512;
            drain(segments);
        }
        pending.erase(pending.begin(), pending.begin() + consumed);
        if (flush) {
            if (!pending.empty()) {
                pending.resize(512, 0); SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, pending.data(), 512); pending.clear();
            }
            SherpaOnnxVoiceActivityDetectorFlush(vad); drain(segments);
        }
        if (history.size() > 16000 * 30) {
            const auto remove = history.size() - 16000 * 30;
            history.erase(history.begin(), history.begin() + remove); historyStart += remove;
        }
        return @{ @"segments": segments, @"speaking": @(SherpaOnnxVoiceActivityDetectorDetected(vad) != 0) };
    }
    void drain(NSMutableArray *segments) {
        while (!SherpaOnnxVoiceActivityDetectorEmpty(vad)) {
            const auto *segment = SherpaOnnxVoiceActivityDetectorFront(vad);
            const auto *stream = SherpaOnnxCreateOfflineStream(recognizer);
            if (!segment || !stream) throw std::runtime_error("asr_stream");
            // Restore up to 200 ms before the VAD boundary so quiet initial consonants and
            // short question words are retained. Never overlap the previous decoded segment.
            int64_t start = std::max(previousEnd, std::max(historyStart, static_cast<int64_t>(segment->start) - 3200));
            const int64_t end = static_cast<int64_t>(segment->start) + segment->n;
            const bool available = start >= historyStart && end <= historyStart + static_cast<int64_t>(history.size());
            if (available) SherpaOnnxAcceptWaveformOffline(stream, 16000, history.data() + start - historyStart, static_cast<int32_t>(end - start));
            else { start = segment->start; SherpaOnnxAcceptWaveformOffline(stream, 16000, segment->samples, segment->n); }
            SherpaOnnxDecodeOfflineStream(recognizer, stream);
            const auto *result = SherpaOnnxGetOfflineStreamResult(stream);
            if (result && result->text) {
                NSString *text = [NSString stringWithUTF8String:result->text];
                if (text.length) [segments addObject:@{ @"text": text, @"start_ms": @(start / 16), @"end_ms": @(end / 16) }];
            }
            if (result) SherpaOnnxDestroyOfflineRecognizerResult(result);
            SherpaOnnxDestroyOfflineStream(stream); SherpaOnnxDestroySpeechSegment(segment);
            SherpaOnnxVoiceActivityDetectorPop(vad);
            previousEnd = end;
        }
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
            std::unique_ptr<SpeechEngine> speech;
            std::unique_ptr<EmbeddingEngine> embedding;
            const std::string mode(argv[1]), root(argv[2]);
            if (mode == "speech") speech = std::make_unique<SpeechEngine>(root);
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
                        else if (speech && ([op isEqual:@"audio"] || [op isEqual:@"flush"])) {
                            NSData *pcm = [op isEqual:@"flush"] ? [NSData data] : [[NSData alloc] initWithBase64EncodedString:command[@"pcm"] options:0];
                            if (!pcm) throw std::runtime_error("audio_base64");
                            [response addEntriesFromDictionary:speech->accept(pcm, [op isEqual:@"flush"])];
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

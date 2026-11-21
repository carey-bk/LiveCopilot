// Native Snowflake Arctic Embed m v2.0 tokenizer (XLM-R style SentencePiece Unigram).
// Bit-exact port of the HuggingFace `tokenizers` pipeline described by the model's
// tokenizer.json: added-token split -> Precompiled (charsmap) -> WhitespaceSplit ->
// Metaspace(prepend always) -> Unigram Viterbi (fuse_unk) -> <s> ... </s>.
// Deliberately ignores the `truncation` block of tokenizer.json (max_length 512): the
// caller enforces the model's real 8,192-token limit and rejects, never truncates.
// Zero third-party dependencies: C++17 standard library + POSIX mmap.
#pragma once
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace lc_arctic {

struct AddedToken {
    std::string content;
    int64_t id = 0;
    bool lstrip = false, rstrip = false, singleWord = false;
};

class Tokenizer {
public:
    // Parses the upstream tokenizer.json directly. Validates every pipeline component
    // and fails closed (returns nullptr) on any unexpected configuration.
    static std::unique_ptr<Tokenizer> loadJSON(const std::string &path, std::string *error = nullptr);
    // Loads the compact binary image produced by saveBinary (mmap, zero copy).
    static std::unique_ptr<Tokenizer> loadBinary(const std::string &path, std::string *error = nullptr);
    bool saveBinary(const std::string &path, const uint8_t sourceSHA256[32]) const;
    ~Tokenizer();

    enum class Result { ok, tokenLimit };
    // Appends <s> ids </s> to `ids` (cleared first). Stops and returns tokenLimit as soon
    // as the count would exceed maxTokens (specials included). Never truncates silently.
    Result encode(std::string_view utf8, std::vector<int64_t> &ids, size_t maxTokens = SIZE_MAX) const;

    // Test hooks.
    std::string normalize(std::string_view segment) const;
    std::vector<std::string> preTokenize(std::string_view normalized) const;
    size_t vocabSize() const { return count; }
    const uint8_t *sourceSHA256() const { return sourceDigest; }

private:
    Tokenizer() = default;
    bool finish(std::string *error);
    bool transform(const char *bytes, size_t length, std::string_view &out) const;
    void encodeSegment(std::string_view segment, std::vector<int64_t> &ids, std::string &scratch) const;
    void encodePiece(std::string_view piece, std::vector<int64_t> &ids) const;
    int64_t lookup(std::string_view piece) const;
    std::string_view piece(uint32_t i) const { return {blob + offsets[i], offsets[i + 1] - offsets[i]}; }

    // Either owned (JSON) or mmap-backed (binary) storage.
    std::vector<char> ownBlob, ownCharsmapNormalized;
    std::vector<uint32_t> ownOffsets, ownSorted, ownTrie;
    std::vector<double> ownScores;
    void *mapping = nullptr;
    size_t mappingSize = 0;

    const char *blob = nullptr;
    const uint32_t *offsets = nullptr;   // count + 1
    const double *scores = nullptr;      // count
    const uint32_t *sorted = nullptr;    // count, lexicographic byte order
    const uint32_t *trie = nullptr;      // darts-clone double array units
    size_t trieUnits = 0;
    const char *charsmapNormalized = nullptr;
    size_t charsmapNormalizedSize = 0;
    size_t count = 0;
    int64_t unkID = 3, bosID = 0, eosID = 2;
    double unkScore = 0;
    std::vector<AddedToken> added;
    uint8_t sourceDigest[32] = {};
};

}  // namespace lc_arctic

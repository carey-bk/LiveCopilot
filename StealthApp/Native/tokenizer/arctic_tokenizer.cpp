#include "arctic_tokenizer.h"
#include "unicode_tables.h"
#include "json_lite.h"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xlocale.h>

namespace lc_arctic {
namespace {

// ---------------------------------------------------------------- UTF-8 helpers
inline size_t utf8Length(unsigned char lead) {
    if (lead < 0x80) return 1;
    if ((lead >> 5) == 0x6) return 2;
    if ((lead >> 4) == 0xE) return 3;
    if ((lead >> 3) == 0x1E) return 4;
    return 1;  // invalid lead byte: treat as a single unit (inputs are validated upstream)
}

inline uint32_t decode(const char *s, size_t n, size_t &len) {
    const auto *u = reinterpret_cast<const unsigned char *>(s);
    len = std::min(utf8Length(u[0]), n);
    switch (len) {
        case 1: return u[0];
        case 2: return ((u[0] & 0x1F) << 6) | (u[1] & 0x3F);
        case 3: return ((u[0] & 0x0F) << 12) | ((u[1] & 0x3F) << 6) | (u[2] & 0x3F);
        default: return ((u[0] & 0x07) << 18) | ((u[1] & 0x3F) << 12) | ((u[2] & 0x3F) << 6) | (u[3] & 0x3F);
    }
}

// Rust char::is_whitespace == Unicode White_Space.
inline bool isWhitespace(uint32_t c) {
    return (c >= 0x9 && c <= 0xD) || c == 0x20 || c == 0x85 || c == 0xA0 || c == 0x1680 ||
           (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000;
}

// ---------------------------------------------------------------- UAX #29 graphemes
enum GCB : uint8_t { Other, CR, LF, Control, Extend, ZWJ, RI, Prepend, SpacingMark, L, V, T, LV, LVT };
enum InCB : uint8_t { InNone, InLinker, InConsonant, InExtend };

inline uint8_t property(uint32_t c) {
    if (c >= 0xAC00 && c <= 0xD7A3) return ((c - 0xAC00) % 28 == 0) ? LV : LVT;  // Hangul syllables
    const auto *runs = lc_arctic_ucd::kRuns;
    size_t lo = 0, hi = sizeof(lc_arctic_ucd::kRuns) / sizeof(lc_arctic_ucd::kRuns[0]);
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (runs[mid].hi < c) lo = mid + 1;
        else if (runs[mid].lo > c) hi = mid;
        else return runs[mid].v;
    }
    return 0;
}

struct GraphemeState {
    uint8_t prev = 0xFF;
    int riCount = 0;
    enum { EmoNone, EmoPict, EmoZWJ } emoji = EmoNone;
    enum { CbNone, CbConsonant, CbLinked } conjunct = CbNone;
    // Returns true when a boundary precedes code point `c`.
    bool boundaryBefore(uint32_t c) {
        const uint8_t packed = property(c);
        const uint8_t g = packed & 0x0F;
        const bool pict = (packed >> 4) & 1;
        const uint8_t incb = (packed >> 5) & 3;
        bool brk;
        const uint8_t p = prev;
        if (p == 0xFF) brk = true;                                                          // GB1
        else if (p == CR && g == LF) brk = false;                                           // GB3
        else if (p == Control || p == CR || p == LF) brk = true;                            // GB4
        else if (g == Control || g == CR || g == LF) brk = true;                            // GB5
        else if (p == L && (g == L || g == V || g == LV || g == LVT)) brk = false;          // GB6
        else if ((p == LV || p == V) && (g == V || g == T)) brk = false;                    // GB7
        else if ((p == LVT || p == T) && g == T) brk = false;                               // GB8
        else if (g == Extend || g == ZWJ) brk = false;                                      // GB9
        else if (g == SpacingMark) brk = false;                                             // GB9a
        else if (p == Prepend) brk = false;                                                 // GB9b
        else if (incb == InConsonant && conjunct == CbLinked) brk = false;                  // GB9c
        else if (p == ZWJ && pict && emoji == EmoZWJ) brk = false;                          // GB11
        else if (p == RI && g == RI && (riCount % 2) == 1) brk = false;                     // GB12/13
        else brk = true;                                                                    // GB999
        // State updates.
        if (pict) emoji = EmoPict;
        else if (g == Extend && emoji == EmoPict) emoji = EmoPict;
        else if (g == ZWJ && emoji == EmoPict) emoji = EmoZWJ;
        else emoji = EmoNone;
        if (incb == InConsonant) conjunct = CbConsonant;
        else if (incb == InLinker && conjunct != CbNone) conjunct = CbLinked;
        else if (incb == InExtend && conjunct != CbNone) { /* keep */ }
        else conjunct = CbNone;
        riCount = (g == RI) ? riCount + 1 : 0;
        prev = g;
        return brk;
    }
};

bool base64(const std::string &in, std::vector<uint8_t> &out) {
    auto val = [](char c) -> int {
        if (c >= 'A' && c <= 'Z') return c - 'A';
        if (c >= 'a' && c <= 'z') return c - 'a' + 26;
        if (c >= '0' && c <= '9') return c - '0' + 52;
        if (c == '+') return 62;
        if (c == '/') return 63;
        return -1;
    };
    out.clear();
    uint32_t acc = 0; int bits = 0;
    for (char c : in) {
        if (c == '=') break;
        int v = val(c);
        if (v < 0) return false;
        acc = (acc << 6) | uint32_t(v); bits += 6;
        if (bits >= 8) { bits -= 8; out.push_back(uint8_t((acc >> bits) & 0xFF)); }
    }
    return true;
}

bool setError(std::string *error, const char *message) {
    if (error) *error = message;
    return false;
}

constexpr char kMagic[8] = {'L', 'C', 'A', 'R', 'C', 'T', 'K', '1'};
struct BinaryHeader {
    char magic[8];
    uint32_t version, count;
    uint64_t blobBytes, trieUnits, normalizedBytes;
    int64_t unkID, bosID, eosID;
    double unkScore;
    uint32_t addedCount, addedBytes;
    uint8_t sourceSHA256[32];
    uint64_t payloadFNV1a;
};

uint64_t fnv1a(const uint8_t *data, size_t n) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; ++i) { h ^= data[i]; h *= 1099511628211ULL; }
    return h;
}

}  // namespace

Tokenizer::~Tokenizer() {
    if (mapping) munmap(mapping, mappingSize);
}

// ------------------------------------------------------------------- loading
std::unique_ptr<Tokenizer> Tokenizer::loadJSON(const std::string &path, std::string *error) {
    std::unique_ptr<Tokenizer> t(new Tokenizer());
    int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) { setError(error, "open"); return nullptr; }
    struct stat st{};
    if (fstat(fd, &st) != 0 || st.st_size <= 0 || st.st_size > (64 << 20)) { close(fd); setError(error, "size"); return nullptr; }
    std::vector<char> text(size_t(st.st_size) + 1, '\0');
    size_t got = 0;
    while (got < size_t(st.st_size)) {
        ssize_t r = read(fd, text.data() + got, size_t(st.st_size) - got);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; break; }
        got += size_t(r);
    }
    close(fd);
    if (got != size_t(st.st_size)) { setError(error, "read"); return nullptr; }

    JsonReader r{text.data(), text.data() + got};
    if (!r.eat('{')) { setError(error, "json"); return nullptr; }
    bool sawModel = false, sawNormalizer = false, sawPre = false, sawPost = false, sawAdded = false;
    std::vector<uint8_t> charsmap;
    std::string key;
    do {
        if (!r.string(key) || !r.eat(':')) { setError(error, "json"); return nullptr; }
        if (key == "model") {
            // Streamed: the vocab holds 250k [piece, score] pairs; avoid a generic DOM.
            if (!r.eat('{')) { setError(error, "model"); return nullptr; }
            std::string mkey, type;
            bool byteFallback = true, sawVocab = false;
            int64_t unk = -1;
            do {
                if (!r.string(mkey) || !r.eat(':')) { setError(error, "model"); return nullptr; }
                if (mkey == "vocab") {
                    sawVocab = true;
                    if (!r.eat('[')) { setError(error, "vocab"); return nullptr; }
                    t->ownOffsets.reserve(250003);
                    t->ownScores.reserve(250002);
                    t->ownBlob.reserve(4 << 20);
                    t->ownOffsets.push_back(0);
                    std::string pieceText;
                    if (!r.eat(']')) {
                        do {
                            double score;
                            if (!r.eat('[') || !r.string(pieceText) || !r.eat(',') || !r.number(score) || !r.eat(']')) {
                                setError(error, "vocab"); return nullptr;
                            }
                            if (pieceText.empty() || !std::isfinite(score)) { setError(error, "vocab"); return nullptr; }
                            t->ownBlob.insert(t->ownBlob.end(), pieceText.begin(), pieceText.end());
                            t->ownOffsets.push_back(uint32_t(t->ownBlob.size()));
                            t->ownScores.push_back(score);
                        } while (r.eat(','));
                        if (!r.eat(']')) { setError(error, "vocab"); return nullptr; }
                    }
                } else {
                    JValue v;
                    if (!r.value(v)) { setError(error, "model"); return nullptr; }
                    if (mkey == "type" && v.type == JValue::String) type = v.string;
                    else if (mkey == "unk_id" && v.type == JValue::Number) unk = int64_t(v.number);
                    else if (mkey == "byte_fallback" && v.type == JValue::Bool) byteFallback = v.boolean;
                    else if (mkey == "fuse_unk" && !(v.type == JValue::Bool && v.boolean)) { setError(error, "fuse_unk"); return nullptr; }
                    else if (mkey != "type" && mkey != "unk_id" && mkey != "byte_fallback" && mkey != "fuse_unk") {
                        setError(error, "model_key"); return nullptr;
                    }
                }
            } while (r.eat(','));
            if (!r.eat('}') || type != "Unigram" || byteFallback || unk != 3 || !sawVocab) { setError(error, "model"); return nullptr; }
            t->unkID = unk;
            sawModel = true;
        } else {
            JValue v;
            if (!r.value(v)) { setError(error, "json"); return nullptr; }
            if (key == "normalizer") {
                const JValue *map = v.get("precompiled_charsmap");
                if (!v.get("type") || !v.get("type")->isString("Precompiled") || !map || map->type != JValue::String || !base64(map->string, charsmap)) {
                    setError(error, "normalizer"); return nullptr;
                }
                sawNormalizer = true;
            } else if (key == "pre_tokenizer") {
                const JValue *list = v.get("pretokenizers");
                if (!v.get("type") || !v.get("type")->isString("Sequence") || !list || list->type != JValue::Array || list->array.size() != 2) {
                    setError(error, "pre_tokenizer"); return nullptr;
                }
                const JValue &ws = list->array[0], &ms = list->array[1];
                const JValue *split = ms.get("split"), *prefix = ms.get("add_prefix_space"), *scheme = ms.get("prepend_scheme");
                if (!ws.get("type") || !ws.get("type")->isString("WhitespaceSplit") || ws.object.size() != 1 ||
                    !ms.get("type") || !ms.get("type")->isString("Metaspace") || !ms.get("replacement") || !ms.get("replacement")->isString("\xE2\x96\x81") ||
                    (split && !(split->type == JValue::Bool && split->boolean)) ||
                    (prefix && !(prefix->type == JValue::Bool && prefix->boolean)) ||
                    !scheme || !scheme->isString("always")) {
                    setError(error, "pre_tokenizer"); return nullptr;
                }
                sawPre = true;
            } else if (key == "post_processor") {
                const JValue *single = v.get("single"), *specials = v.get("special_tokens");
                auto special = [&](const JValue &item, const char *name) {
                    const JValue *s = item.get("SpecialToken");
                    return s && s->get("id") && s->get("id")->isString(name);
                };
                auto specialID = [&](const char *name) -> int64_t {
                    const JValue *s = specials ? specials->get(name) : nullptr;
                    const JValue *ids = s ? s->get("ids") : nullptr;
                    if (!ids || ids->type != JValue::Array || ids->array.size() != 1 || ids->array[0].type != JValue::Number) return -1;
                    return int64_t(ids->array[0].number);
                };
                if (!v.get("type") || !v.get("type")->isString("TemplateProcessing") || !single || single->type != JValue::Array ||
                    single->array.size() != 3 || !special(single->array[0], "<s>") || !single->array[1].get("Sequence") ||
                    !special(single->array[2], "</s>") || specialID("<s>") != 0 || specialID("</s>") != 2) {
                    setError(error, "post_processor"); return nullptr;
                }
                t->bosID = 0; t->eosID = 2;
                sawPost = true;
            } else if (key == "added_tokens") {
                if (v.type != JValue::Array) { setError(error, "added_tokens"); return nullptr; }
                for (auto &item : v.array) {
                    const JValue *id = item.get("id"), *content = item.get("content"), *normalized = item.get("normalized");
                    if (!id || id->type != JValue::Number || !content || content->type != JValue::String || content->string.empty() ||
                        !normalized || normalized->type != JValue::Bool || normalized->boolean) {
                        setError(error, "added_tokens"); return nullptr;  // only raw-text (normalized:false) tokens are supported
                    }
                    AddedToken a;
                    a.id = int64_t(id->number); a.content = content->string;
                    auto flag = [&](const char *name) { const JValue *f = item.get(name); return f && f->type == JValue::Bool && f->boolean; };
                    a.lstrip = flag("lstrip"); a.rstrip = flag("rstrip"); a.singleWord = flag("single_word");
                    t->added.push_back(std::move(a));
                }
                sawAdded = true;
            } else if (key == "decoder" || key == "truncation" || key == "padding" || key == "version") {
                // Decoder is unused for embeddings. `truncation` (max_length 512) is intentionally ignored.
            } else { setError(error, "unknown_key"); return nullptr; }
        }
    } while (r.eat(','));
    if (!r.eat('}') || r.failed || !sawModel || !sawNormalizer || !sawPre || !sawPost || !sawAdded) { setError(error, "incomplete"); return nullptr; }

    // spm_precompiled layout: u32 trie byte size, darts units, NUL-separated replacement strings.
    if (charsmap.size() < 4) { setError(error, "charsmap"); return nullptr; }
    uint32_t trieBytes;
    memcpy(&trieBytes, charsmap.data(), 4);
    if (trieBytes % 4 || size_t(trieBytes) + 4 > charsmap.size()) { setError(error, "charsmap"); return nullptr; }
    t->ownTrie.resize(trieBytes / 4);
    memcpy(t->ownTrie.data(), charsmap.data() + 4, trieBytes);
    t->ownCharsmapNormalized.assign(charsmap.begin() + 4 + trieBytes, charsmap.end());

    t->count = t->ownScores.size();
    t->ownSorted.resize(t->count);
    for (uint32_t i = 0; i < t->count; ++i) t->ownSorted[i] = i;
    const char *b = t->ownBlob.data();
    const uint32_t *o = t->ownOffsets.data();
    std::sort(t->ownSorted.begin(), t->ownSorted.end(), [&](uint32_t x, uint32_t y) {
        return std::string_view(b + o[x], o[x + 1] - o[x]) < std::string_view(b + o[y], o[y + 1] - o[y]);
    });
    double minScore = INFINITY;
    for (double s : t->ownScores) minScore = std::min(minScore, s);
    t->unkScore = minScore - 10.0;  // K_UNK_PENALTY
    t->blob = t->ownBlob.data(); t->offsets = t->ownOffsets.data(); t->scores = t->ownScores.data();
    t->sorted = t->ownSorted.data(); t->trie = t->ownTrie.data(); t->trieUnits = t->ownTrie.size();
    t->charsmapNormalized = t->ownCharsmapNormalized.data(); t->charsmapNormalizedSize = t->ownCharsmapNormalized.size();
    if (!t->finish(error)) return nullptr;
    return t;
}

bool Tokenizer::finish(std::string *error) {
    if (count < 4 || size_t(unkID) >= count || trieUnits == 0) return setError(error, "vocab");
    for (size_t i = 1; i < count; ++i)
        if (piece(sorted[i - 1]) == piece(sorted[i])) return setError(error, "duplicate_piece");
    for (auto &a : added) if (a.id < 0 || size_t(a.id) >= count) return setError(error, "added_id");
    // Leftmost-longest matching: try longer added tokens first at a position.
    std::stable_sort(added.begin(), added.end(), [](const AddedToken &x, const AddedToken &y) { return x.content.size() > y.content.size(); });
    return true;
}

bool Tokenizer::saveBinary(const std::string &path, const uint8_t sourceSHA256[32]) const {
    std::string addedBlob;
    for (auto &a : added) {
        uint32_t n = uint32_t(a.content.size());
        addedBlob.append(reinterpret_cast<const char *>(&a.id), 8);
        addedBlob += char(a.lstrip); addedBlob += char(a.rstrip); addedBlob += char(a.singleWord); addedBlob += char(0);
        addedBlob.append(reinterpret_cast<const char *>(&n), 4);
        addedBlob += a.content;
    }
    std::string payload;
    auto put = [&](const void *data, size_t n) { payload.append(static_cast<const char *>(data), n); while (payload.size() % 8) payload += '\0'; };
    put(offsets, (count + 1) * 4);
    put(scores, count * 8);
    put(sorted, count * 4);
    put(trie, trieUnits * 4);
    put(blob, offsets[count]);
    put(charsmapNormalized, charsmapNormalizedSize);
    put(addedBlob.data(), addedBlob.size());
    BinaryHeader h{};
    memcpy(h.magic, kMagic, 8);
    h.version = 1; h.count = uint32_t(count); h.blobBytes = offsets[count]; h.trieUnits = trieUnits;
    h.normalizedBytes = charsmapNormalizedSize; h.unkID = unkID; h.bosID = bosID; h.eosID = eosID; h.unkScore = unkScore;
    h.addedCount = uint32_t(added.size()); h.addedBytes = uint32_t(addedBlob.size());
    memcpy(h.sourceSHA256, sourceSHA256, 32);
    h.payloadFNV1a = fnv1a(reinterpret_cast<const uint8_t *>(payload.data()), payload.size());
    std::string temp = path + ".tmp";
    FILE *f = fopen(temp.c_str(), "wb");
    if (!f) return false;
    bool ok = fwrite(&h, sizeof h, 1, f) == 1 && fwrite(payload.data(), 1, payload.size(), f) == payload.size();
    ok = (fclose(f) == 0) && ok;
    return ok && rename(temp.c_str(), path.c_str()) == 0;
}

std::unique_ptr<Tokenizer> Tokenizer::loadBinary(const std::string &path, std::string *error) {
    std::unique_ptr<Tokenizer> t(new Tokenizer());
    int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) { setError(error, "open"); return nullptr; }
    struct stat st{};
    if (fstat(fd, &st) != 0 || size_t(st.st_size) < sizeof(BinaryHeader) || st.st_size > (64 << 20)) { close(fd); setError(error, "size"); return nullptr; }
    void *m = mmap(nullptr, size_t(st.st_size), PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (m == MAP_FAILED) { setError(error, "mmap"); return nullptr; }
    t->mapping = m; t->mappingSize = size_t(st.st_size);
    BinaryHeader h;
    memcpy(&h, m, sizeof h);
    if (memcmp(h.magic, kMagic, 8) != 0 || h.version != 1 || h.count < 4) { setError(error, "header"); return nullptr; }
    auto padded = [](uint64_t n) { return (n + 7) & ~uint64_t(7); };
    const uint64_t need = padded((uint64_t(h.count) + 1) * 4) + padded(uint64_t(h.count) * 8) + padded(uint64_t(h.count) * 4) +
                          padded(h.trieUnits * 4) + padded(h.blobBytes) + padded(h.normalizedBytes) + padded(h.addedBytes);
    if (sizeof h + need != uint64_t(st.st_size)) { setError(error, "length"); return nullptr; }
    const uint8_t *p = static_cast<const uint8_t *>(m) + sizeof h;
#ifdef LC_ARCTIC_VERIFY_BINARY
    if (fnv1a(p, size_t(need)) != h.payloadFNV1a) { setError(error, "checksum"); return nullptr; }
#endif
    t->count = h.count;
    t->offsets = reinterpret_cast<const uint32_t *>(p); p += padded((uint64_t(h.count) + 1) * 4);
    t->scores = reinterpret_cast<const double *>(p); p += padded(uint64_t(h.count) * 8);
    t->sorted = reinterpret_cast<const uint32_t *>(p); p += padded(uint64_t(h.count) * 4);
    t->trie = reinterpret_cast<const uint32_t *>(p); t->trieUnits = h.trieUnits; p += padded(h.trieUnits * 4);
    t->blob = reinterpret_cast<const char *>(p); p += padded(h.blobBytes);
    t->charsmapNormalized = reinterpret_cast<const char *>(p); t->charsmapNormalizedSize = h.normalizedBytes; p += padded(h.normalizedBytes);
    // Bounds validation (O(n)): offsets monotonic and inside the blob; sorted indices in range.
    if (t->offsets[0] != 0 || t->offsets[h.count] != h.blobBytes) { setError(error, "offsets"); return nullptr; }
    for (uint32_t i = 0; i < h.count; ++i)
        if (t->offsets[i + 1] <= t->offsets[i] || t->sorted[i] >= h.count) { setError(error, "offsets"); return nullptr; }
    const uint8_t *a = p, *aend = p + h.addedBytes;
    for (uint32_t i = 0; i < h.addedCount; ++i) {
        if (aend - a < 16) { setError(error, "added"); return nullptr; }
        AddedToken tok;
        uint32_t n;
        memcpy(&tok.id, a, 8); tok.lstrip = a[8]; tok.rstrip = a[9]; tok.singleWord = a[10];
        memcpy(&n, a + 12, 4); a += 16;
        if (size_t(aend - a) < n) { setError(error, "added"); return nullptr; }
        tok.content.assign(reinterpret_cast<const char *>(a), n); a += n;
        t->added.push_back(std::move(tok));
    }
    t->unkID = h.unkID; t->bosID = h.bosID; t->eosID = h.eosID; t->unkScore = h.unkScore;
    memcpy(t->sourceDigest, h.sourceSHA256, 32);
    if (!t->finish(error)) return nullptr;
    return t;
}

// ------------------------------------------------------------------- normalizer
// darts-clone common prefix search; like spm_precompiled, the *first* (shortest) hit wins.
bool Tokenizer::transform(const char *bytes, size_t length, std::string_view &out) const {
    auto offset = [](uint32_t u) -> size_t { return size_t(u >> 10) << ((u & (1u << 9)) >> 6); };
    auto label = [](uint32_t u) -> uint32_t { return u & ((1u << 31) | 0xFF); };
    auto hasLeaf = [](uint32_t u) -> bool { return (u >> 8) & 1; };
    auto value = [](uint32_t u) -> uint32_t { return u & ((1u << 31) - 1); };
    size_t node = 0;
    uint32_t unit = trie[node];
    node ^= offset(unit);
    for (size_t i = 0; i < length; ++i) {
        const uint8_t c = uint8_t(bytes[i]);
        if (c == 0) break;
        node ^= c;
        if (node >= trieUnits) return false;
        unit = trie[node];
        if (label(unit) != c) return false;
        node ^= offset(unit);
        if (node >= trieUnits) return false;
        if (hasLeaf(unit)) {
            const size_t start = value(trie[node]);
            if (start >= charsmapNormalizedSize) return false;
            const char *s = charsmapNormalized + start;
            out = std::string_view(s, strnlen(s, charsmapNormalizedSize - start));
            return true;
        }
    }
    return false;
}

std::string Tokenizer::normalize(std::string_view text) const {
    std::string out;
    out.reserve(text.size() + 16);
    GraphemeState state;
    size_t i = 0, start = 0;
    auto flush = [&](size_t gs, size_t ge) {
        std::string_view replacement;
        if (ge - gs < 6 && transform(text.data() + gs, ge - gs, replacement)) { out += replacement; return; }
        for (size_t k = gs; k < ge;) {
            size_t len;
            decode(text.data() + k, ge - k, len);
            if (transform(text.data() + k, len, replacement)) out += replacement;
            else out.append(text.data() + k, len);
            k += len;
        }
    };
    while (i < text.size()) {
        size_t len;
        uint32_t c = decode(text.data() + i, text.size() - i, len);
        if (state.boundaryBefore(c) && i > start) { flush(start, i); start = i; }
        i += len;
    }
    if (i > start) flush(start, i);
    return out;
}

std::vector<std::string> Tokenizer::preTokenize(std::string_view normalized) const {
    std::vector<std::string> words;
    size_t i = 0;
    std::string current;
    auto emit = [&]() {
        if (current.empty()) return;
        static const std::string_view meta = "\xE2\x96\x81";
        std::string w = current.compare(0, 3, meta) == 0 ? current : std::string(meta) + current;
        // Metaspace split (MergedWithNext): every U+2581 starts a new piece.
        size_t s = 0;
        for (size_t k = 3; k + 3 <= w.size();) {
            if (w.compare(k, 3, meta) == 0) { words.push_back(w.substr(s, k - s)); s = k; k += 3; }
            else k += utf8Length(uint8_t(w[k]));
        }
        words.push_back(w.substr(s));
        current.clear();
    };
    while (i < normalized.size()) {
        size_t len;
        uint32_t c = decode(normalized.data() + i, normalized.size() - i, len);
        if (isWhitespace(c)) emit();
        else current.append(normalized.data() + i, len);
        i += len;
    }
    emit();
    return words;
}

// ------------------------------------------------------------------- Unigram
int64_t Tokenizer::lookup(std::string_view key) const {
    size_t lo = 0, hi = count;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        auto p = piece(sorted[mid]);
        if (p < key) lo = mid + 1; else hi = mid;
    }
    return (lo < count && piece(sorted[lo]) == key) ? int64_t(sorted[lo]) : unkID;
}

void Tokenizer::encodePiece(std::string_view s, std::vector<int64_t> &ids) const {
    struct Node { double score = 0; int64_t id = -1; int32_t start = -1; };
    const size_t size = s.size();
    std::vector<Node> best(size + 1);
    for (size_t pos = 0; pos < size;) {
        const double base = best[pos].score;
        const size_t mblen = std::min(utf8Length(uint8_t(s[pos])), size - pos);
        bool single = false;
        size_t lo = 0, hi = count;
        for (size_t d = 0; pos + d < size; ++d) {
            const int c = uint8_t(s[pos + d]);
            auto keyAt = [&](uint32_t idx) -> int {
                const uint32_t len = offsets[idx + 1] - offsets[idx];
                return len > d ? int(uint8_t(blob[offsets[idx] + d])) : -1;
            };
            size_t a = lo, b = hi;  // lower_bound(c)
            while (a < b) { size_t m = (a + b) / 2; if (keyAt(sorted[m]) < c) a = m + 1; else b = m; }
            size_t e = a, f = hi;   // upper_bound(c)
            while (e < f) { size_t m = (e + f) / 2; if (keyAt(sorted[m]) <= c) e = m + 1; else f = m; }
            lo = a; hi = e;
            if (lo >= hi) break;
            const uint32_t idx = sorted[lo];
            if (offsets[idx + 1] - offsets[idx] == d + 1) {
                const size_t key = pos + d + 1;
                const double candidate = scores[idx] + base;
                if (best[key].start < 0 || candidate > best[key].score) {
                    best[key].score = candidate; best[key].start = int32_t(pos); best[key].id = idx;
                }
                if (d + 1 == mblen) single = true;
            }
        }
        if (!single) {
            const size_t key = pos + mblen;
            const double candidate = unkScore + base;
            if (best[key].start < 0 || candidate > best[key].score) {
                best[key].score = candidate; best[key].start = int32_t(pos); best[key].id = unkID;
            }
        }
        pos += mblen;
    }
    // Backtrack; consecutive unknowns are fused (HF Unigram fuse_unk = true).
    std::vector<std::pair<size_t, int64_t>> path;  // (start, id), reversed
    for (size_t end = size; end > 0;) {
        const Node &n = best[end];
        path.emplace_back(size_t(n.start), n.id);
        end = size_t(n.start);
    }
    std::reverse(path.begin(), path.end());
    for (size_t k = 0; k < path.size();) {
        if (path[k].second != unkID) { ids.push_back(path[k].second); ++k; continue; }
        size_t j = k;
        while (j < path.size() && path[j].second == unkID) ++j;
        const size_t from = path[k].first, to = j < path.size() ? path[j].first : size;
        ids.push_back(j - k == 1 ? unkID : lookup(s.substr(from, to - from)));
        k = j;
    }
}

void Tokenizer::encodeSegment(std::string_view segment, std::vector<int64_t> &ids, std::string &) const {
    if (segment.empty()) return;
    const std::string normalized = normalize(segment);
    for (const auto &word : preTokenize(normalized)) encodePiece(word, ids);
}

Tokenizer::Result Tokenizer::encode(std::string_view text, std::vector<int64_t> &ids, size_t maxTokens) const {
    ids.clear();
    ids.push_back(bosID);
    std::string scratch;
    // Added (special) tokens are matched on raw text, leftmost-longest, before normalization.
    size_t segmentStart = 0, i = 0;
    auto lastNonSpaceEnd = [&](size_t from, size_t to) {
        size_t k = from, endNonSpace = from;
        while (k < to) {
            size_t len;
            uint32_t c = decode(text.data() + k, to - k, len);
            if (!isWhitespace(c)) endNonSpace = k + len;
            k += len;
        }
        return endNonSpace;
    };
    while (i < text.size()) {
        const AddedToken *hit = nullptr;
        for (auto &a : added)
            if (text[i] == a.content[0] && text.compare(i, a.content.size(), a.content) == 0) { hit = &a; break; }
        if (!hit) { i += utf8Length(uint8_t(text[i])); continue; }
        size_t start = i, stop = i + hit->content.size();
        if (hit->singleWord) { /* unused by Arctic; rejected nowhere but never set */ }
        if (hit->lstrip) start = std::max(lastNonSpaceEnd(segmentStart, start), segmentStart);
        if (hit->rstrip) {
            size_t k = stop;
            while (k < text.size()) { size_t len; uint32_t c = decode(text.data() + k, text.size() - k, len); if (!isWhitespace(c)) break; k += len; }
            stop = k;
        }
        encodeSegment(text.substr(segmentStart, start - segmentStart), ids, scratch);
        ids.push_back(hit->id);
        segmentStart = i = stop;
        if (ids.size() + 1 > maxTokens) return Result::tokenLimit;
    }
    encodeSegment(text.substr(segmentStart), ids, scratch);
    ids.push_back(eosID);
    return ids.size() > maxTokens ? Result::tokenLimit : Result::ok;
}

}  // namespace lc_arctic

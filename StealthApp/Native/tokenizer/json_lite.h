// Minimal, dependency-free JSON reader shared by the tokenizer loader and test tools.
#pragma once
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>
#include <utility>
#include <vector>
#include <xlocale.h>

namespace lc_arctic {
inline void appendUTF8(std::string &out, uint32_t c) {
    if (c < 0x80) out += char(c);
    else if (c < 0x800) { out += char(0xC0 | (c >> 6)); out += char(0x80 | (c & 0x3F)); }
    else if (c < 0x10000) { out += char(0xE0 | (c >> 12)); out += char(0x80 | ((c >> 6) & 0x3F)); out += char(0x80 | (c & 0x3F)); }
    else { out += char(0xF0 | (c >> 18)); out += char(0x80 | ((c >> 12) & 0x3F)); out += char(0x80 | ((c >> 6) & 0x3F)); out += char(0x80 | (c & 0x3F)); }
}
// ---------------------------------------------------------------- minimal JSON reader
struct JValue {
    enum Type { Null, Bool, Number, String, Array, Object } type = Null;
    bool boolean = false;
    double number = 0;
    std::string string;
    std::vector<JValue> array;
    std::vector<std::pair<std::string, JValue>> object;
    const JValue *get(std::string_view key) const {
        for (auto &kv : object) if (kv.first == key) return &kv.second;
        return nullptr;
    }
    bool isString(std::string_view s) const { return type == String && string == s; }
};

inline locale_t cLocale() {
    static locale_t loc = newlocale(LC_ALL_MASK, "C", nullptr);
    return loc;
}

struct JsonReader {
    const char *p, *end;
    bool failed = false;
    void ws() { while (p < end && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t')) ++p; }
    bool eat(char c) { ws(); if (p < end && *p == c) { ++p; return true; } return false; }
    bool fail() { failed = true; return false; }
    static int hex(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }
    bool hex4(uint32_t &v) {
        if (end - p < 4) return fail();
        v = 0;
        for (int i = 0; i < 4; ++i) { int h = hex(p[i]); if (h < 0) return fail(); v = v * 16 + h; }
        p += 4;
        return true;
    }
    bool string(std::string &out) {
        out.clear();
        if (!eat('"')) return fail();
        while (p < end) {
            const char *run = p;
            while (p < end && *p != '"' && *p != '\\') ++p;
            out.append(run, p - run);
            if (p >= end) return fail();
            if (*p == '"') { ++p; return true; }
            ++p;  // backslash
            if (p >= end) return fail();
            char e = *p++;
            switch (e) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    uint32_t c;
                    if (!hex4(c)) return false;
                    if (c >= 0xD800 && c <= 0xDBFF) {
                        uint32_t lo;
                        if (end - p < 6 || p[0] != '\\' || p[1] != 'u') return fail();
                        p += 2;
                        if (!hex4(lo) || lo < 0xDC00 || lo > 0xDFFF) return fail();
                        c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00);
                    } else if (c >= 0xDC00 && c <= 0xDFFF) return fail();
                    appendUTF8(out, c);
                    break;
                }
                default: return fail();
            }
        }
        return fail();
    }
    bool number(double &v) {
        ws();
        char *stop = nullptr;
        // The file buffer is NUL-terminated, so strtod cannot run past the end.
        v = strtod_l(p, &stop, cLocale());
        if (stop == p) return fail();
        p = stop;
        return true;
    }
    bool literal(const char *word) {
        size_t n = strlen(word);
        if (size_t(end - p) < n || memcmp(p, word, n) != 0) return fail();
        p += n;
        return true;
    }
    bool value(JValue &v, int depth = 0) {
        if (depth > 64) return fail();
        ws();
        if (p >= end) return fail();
        switch (*p) {
            case '{': {
                ++p; v.type = JValue::Object;
                if (eat('}')) return true;
                do {
                    std::string key;
                    if (!string(key) || !eat(':')) return fail();
                    v.object.emplace_back(std::move(key), JValue());
                    if (!value(v.object.back().second, depth + 1)) return false;
                } while (eat(','));
                return eat('}') || fail();
            }
            case '[': {
                ++p; v.type = JValue::Array;
                if (eat(']')) return true;
                do {
                    v.array.emplace_back();
                    if (!value(v.array.back(), depth + 1)) return false;
                } while (eat(','));
                return eat(']') || fail();
            }
            case '"': v.type = JValue::String; return string(v.string);
            case 't': v.type = JValue::Bool; v.boolean = true; return literal("true");
            case 'f': v.type = JValue::Bool; v.boolean = false; return literal("false");
            case 'n': v.type = JValue::Null; return literal("null");
            default: v.type = JValue::Number; return number(v.number);
        }
    }
};

}  // namespace lc_arctic

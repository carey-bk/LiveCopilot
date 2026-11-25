import Foundation

/// Languages Apple's on-device SpeechTranscriber offers (macOS 26). The raw value is the saved
/// setting, so existing values (`zh_CN`, `en_US`) keep their meaning. Pickers show only the ones
/// this Mac reports as supported.
enum AppleSpeechLanguage: String, Codable, CaseIterable, Identifiable {
    case chinese = "zh_CN", mandarinTaiwan = "zh_TW", cantoneseHongKong = "zh_HK", cantonese = "yue_CN"
    case english = "en_US", englishUK = "en_GB", englishAustralia = "en_AU", englishCanada = "en_CA"
    case englishIndia = "en_IN", englishSingapore = "en_SG"
    case japanese = "ja_JP", korean = "ko_KR"
    case french = "fr_FR", frenchCanada = "fr_CA", german = "de_DE", italian = "it_IT"
    case spanish = "es_ES", spanishMexico = "es_MX", spanishUS = "es_US"
    case portugueseBrazil = "pt_BR", portugal = "pt_PT"
    case hindi = "hi_IN", bengali = "bn_IN", tamil = "ta_IN", telugu = "te_IN", marathi = "mr_IN"
    case gujarati = "gu_IN", kannada = "kn_IN", malayalam = "ml_IN", punjabi = "pa_IN", urdu = "ur_IN"

    var id: String { rawValue }
    var bcp47: String { rawValue.replacingOccurrences(of: "_", with: "-") }
    var label: String { names.en }

    enum Group: CaseIterable { case chinese, english, other, india }
    var group: Group {
        switch self {
        case .chinese, .mandarinTaiwan, .cantoneseHongKong, .cantonese: return .chinese
        case .english, .englishUK, .englishAustralia, .englishCanada, .englishIndia, .englishSingapore: return .english
        case .hindi, .bengali, .tamil, .telugu, .marathi, .gujarati, .kannada, .malayalam, .punjabi, .urdu: return .india
        default: return .other
        }
    }

    /// English and Chinese display names; Traditional Chinese comes from the shared transform.
    var names: (en: String, zh: String) {
        switch self {
        case .chinese: return ("Mandarin (Mainland China)", "普通话")
        case .mandarinTaiwan: return ("Mandarin (Taiwan)", "普通话（台湾）")
        case .cantoneseHongKong: return ("Cantonese (Hong Kong)", "粤语（香港）")
        case .cantonese: return ("Cantonese (Mainland China)", "粤语（中国大陆）")
        case .english: return ("English (US)", "英语（美国）")
        case .englishUK: return ("English (UK)", "英语（英国）")
        case .englishAustralia: return ("English (Australia)", "英语（澳大利亚）")
        case .englishCanada: return ("English (Canada)", "英语（加拿大）")
        case .englishIndia: return ("English (India)", "英语（印度）")
        case .englishSingapore: return ("English (Singapore)", "英语（新加坡）")
        case .japanese: return ("Japanese", "日语")
        case .korean: return ("Korean", "韩语")
        case .french: return ("French (France)", "法语（法国）")
        case .frenchCanada: return ("French (Canada)", "法语（加拿大）")
        case .german: return ("German", "德语")
        case .italian: return ("Italian", "意大利语")
        case .spanish: return ("Spanish (Spain)", "西班牙语（西班牙）")
        case .spanishMexico: return ("Spanish (Mexico)", "西班牙语（墨西哥）")
        case .spanishUS: return ("Spanish (US)", "西班牙语（美国）")
        case .portugueseBrazil: return ("Portuguese (Brazil)", "葡萄牙语（巴西）")
        case .portugal: return ("Portuguese (Portugal)", "葡萄牙语（葡萄牙）")
        case .hindi: return ("Hindi", "印地语")
        case .bengali: return ("Bengali", "孟加拉语")
        case .tamil: return ("Tamil", "泰米尔语")
        case .telugu: return ("Telugu", "泰卢固语")
        case .marathi: return ("Marathi", "马拉地语")
        case .gujarati: return ("Gujarati", "古吉拉特语")
        case .kannada: return ("Kannada", "卡纳达语")
        case .malayalam: return ("Malayalam", "马拉雅拉姆语")
        case .punjabi: return ("Punjabi", "旁遮普语")
        case .urdu: return ("Urdu", "乌尔都语")
        }
    }
}

/// Keep revisable time ranges separate from committed speech. Apple may finalize
/// only the beginning of an earlier preview, then revise the remaining range.
struct SpeechPreviewState {
    struct Part: Equatable { let startMS: Int; let endMS: Int; let text: String }
    private(set) var committedThrough = -1
    private var parts: [Part] = []
    var preview: String { parts.sorted { $0.startMS < $1.startMS }.map(\.text).joined(separator: " ") }
    mutating func accept(startMS: Int, endMS: Int, text: String, final: Bool) -> Part? {
        guard endMS > committedThrough, endMS >= startMS else { return nil }
        parts.removeAll { $0.startMS < endMS && $0.endMS > startMS || $0.startMS == startMS }
        let part = Part(startMS: max(startMS, committedThrough), endMS: endMS, text: text)
        if final {
            committedThrough = endMS
            parts.removeAll { $0.endMS <= endMS }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : part
        }
        if !text.isEmpty { parts.append(part) }
        return nil
    }
}

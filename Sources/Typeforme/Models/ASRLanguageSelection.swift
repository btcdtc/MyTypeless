import Foundation

enum ChineseScriptPreference: Sendable, Hashable {
    case simplified
    case traditional
    case preserve
}

struct ASRLanguageOption: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let whisperCode: String
    let chineseScript: ChineseScriptPreference
    let commonRank: Int?

    init(
        id: String,
        displayName: String,
        whisperCode: String,
        chineseScript: ChineseScriptPreference = .preserve,
        commonRank: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.whisperCode = whisperCode
        self.chineseScript = chineseScript
        self.commonRank = commonRank
    }

    var isCommon: Bool { commonRank != nil }
}

enum ASRLanguageSelection {
    static let defaultIDs = ["zh-CN", "en-US"]
    static let defaultRawValue = rawValue(for: defaultIDs)

    static let all: [ASRLanguageOption] = [
        ASRLanguageOption(id: "zh-CN", displayName: "Chinese (Simplified)", whisperCode: "zh", chineseScript: .simplified, commonRank: 0),
        ASRLanguageOption(id: "zh-TW", displayName: "Chinese (Traditional)", whisperCode: "zh", chineseScript: .traditional, commonRank: 1),
        ASRLanguageOption(id: "en-US", displayName: "English", whisperCode: "en", commonRank: 2),
        ASRLanguageOption(id: "ja", displayName: "Japanese", whisperCode: "ja", commonRank: 3),
        ASRLanguageOption(id: "ko", displayName: "Korean", whisperCode: "ko", commonRank: 4),
        ASRLanguageOption(id: "fr", displayName: "French", whisperCode: "fr", commonRank: 5),
        ASRLanguageOption(id: "de", displayName: "German", whisperCode: "de", commonRank: 6),
        ASRLanguageOption(id: "es", displayName: "Spanish", whisperCode: "es", commonRank: 7),
        ASRLanguageOption(id: "af", displayName: "Afrikaans", whisperCode: "af"),
        ASRLanguageOption(id: "sq", displayName: "Albanian", whisperCode: "sq"),
        ASRLanguageOption(id: "am", displayName: "Amharic", whisperCode: "am"),
        ASRLanguageOption(id: "ar", displayName: "Arabic", whisperCode: "ar"),
        ASRLanguageOption(id: "hy", displayName: "Armenian", whisperCode: "hy"),
        ASRLanguageOption(id: "as", displayName: "Assamese", whisperCode: "as"),
        ASRLanguageOption(id: "az", displayName: "Azerbaijani", whisperCode: "az"),
        ASRLanguageOption(id: "ba", displayName: "Bashkir", whisperCode: "ba"),
        ASRLanguageOption(id: "eu", displayName: "Basque", whisperCode: "eu"),
        ASRLanguageOption(id: "be", displayName: "Belarusian", whisperCode: "be"),
        ASRLanguageOption(id: "bn", displayName: "Bengali", whisperCode: "bn"),
        ASRLanguageOption(id: "bs", displayName: "Bosnian", whisperCode: "bs"),
        ASRLanguageOption(id: "br", displayName: "Breton", whisperCode: "br"),
        ASRLanguageOption(id: "bg", displayName: "Bulgarian", whisperCode: "bg"),
        ASRLanguageOption(id: "my", displayName: "Burmese / Myanmar", whisperCode: "my"),
        ASRLanguageOption(id: "ca", displayName: "Catalan", whisperCode: "ca"),
        ASRLanguageOption(id: "yue", displayName: "Cantonese", whisperCode: "yue"),
        ASRLanguageOption(id: "hr", displayName: "Croatian", whisperCode: "hr"),
        ASRLanguageOption(id: "cs", displayName: "Czech", whisperCode: "cs"),
        ASRLanguageOption(id: "da", displayName: "Danish", whisperCode: "da"),
        ASRLanguageOption(id: "nl", displayName: "Dutch", whisperCode: "nl"),
        ASRLanguageOption(id: "et", displayName: "Estonian", whisperCode: "et"),
        ASRLanguageOption(id: "fo", displayName: "Faroese", whisperCode: "fo"),
        ASRLanguageOption(id: "fi", displayName: "Finnish", whisperCode: "fi"),
        ASRLanguageOption(id: "gl", displayName: "Galician", whisperCode: "gl"),
        ASRLanguageOption(id: "ka", displayName: "Georgian", whisperCode: "ka"),
        ASRLanguageOption(id: "el", displayName: "Greek", whisperCode: "el"),
        ASRLanguageOption(id: "gu", displayName: "Gujarati", whisperCode: "gu"),
        ASRLanguageOption(id: "ht", displayName: "Haitian Creole", whisperCode: "ht"),
        ASRLanguageOption(id: "ha", displayName: "Hausa", whisperCode: "ha"),
        ASRLanguageOption(id: "haw", displayName: "Hawaiian", whisperCode: "haw"),
        ASRLanguageOption(id: "he", displayName: "Hebrew", whisperCode: "he"),
        ASRLanguageOption(id: "hi", displayName: "Hindi", whisperCode: "hi"),
        ASRLanguageOption(id: "hu", displayName: "Hungarian", whisperCode: "hu"),
        ASRLanguageOption(id: "is", displayName: "Icelandic", whisperCode: "is"),
        ASRLanguageOption(id: "id", displayName: "Indonesian", whisperCode: "id"),
        ASRLanguageOption(id: "it", displayName: "Italian", whisperCode: "it"),
        ASRLanguageOption(id: "jw", displayName: "Javanese", whisperCode: "jw"),
        ASRLanguageOption(id: "kn", displayName: "Kannada", whisperCode: "kn"),
        ASRLanguageOption(id: "kk", displayName: "Kazakh", whisperCode: "kk"),
        ASRLanguageOption(id: "km", displayName: "Khmer", whisperCode: "km"),
        ASRLanguageOption(id: "lo", displayName: "Lao", whisperCode: "lo"),
        ASRLanguageOption(id: "la", displayName: "Latin", whisperCode: "la"),
        ASRLanguageOption(id: "lv", displayName: "Latvian", whisperCode: "lv"),
        ASRLanguageOption(id: "ln", displayName: "Lingala", whisperCode: "ln"),
        ASRLanguageOption(id: "lt", displayName: "Lithuanian", whisperCode: "lt"),
        ASRLanguageOption(id: "lb", displayName: "Luxembourgish", whisperCode: "lb"),
        ASRLanguageOption(id: "mk", displayName: "Macedonian", whisperCode: "mk"),
        ASRLanguageOption(id: "mg", displayName: "Malagasy", whisperCode: "mg"),
        ASRLanguageOption(id: "ms", displayName: "Malay", whisperCode: "ms"),
        ASRLanguageOption(id: "ml", displayName: "Malayalam", whisperCode: "ml"),
        ASRLanguageOption(id: "mt", displayName: "Maltese", whisperCode: "mt"),
        ASRLanguageOption(id: "mi", displayName: "Maori", whisperCode: "mi"),
        ASRLanguageOption(id: "mr", displayName: "Marathi", whisperCode: "mr"),
        ASRLanguageOption(id: "mn", displayName: "Mongolian", whisperCode: "mn"),
        ASRLanguageOption(id: "ne", displayName: "Nepali", whisperCode: "ne"),
        ASRLanguageOption(id: "no", displayName: "Norwegian", whisperCode: "no"),
        ASRLanguageOption(id: "nn", displayName: "Norwegian Nynorsk", whisperCode: "nn"),
        ASRLanguageOption(id: "oc", displayName: "Occitan", whisperCode: "oc"),
        ASRLanguageOption(id: "ps", displayName: "Pashto", whisperCode: "ps"),
        ASRLanguageOption(id: "fa", displayName: "Persian", whisperCode: "fa"),
        ASRLanguageOption(id: "pl", displayName: "Polish", whisperCode: "pl"),
        ASRLanguageOption(id: "pt", displayName: "Portuguese", whisperCode: "pt"),
        ASRLanguageOption(id: "pa", displayName: "Punjabi", whisperCode: "pa"),
        ASRLanguageOption(id: "ro", displayName: "Romanian", whisperCode: "ro"),
        ASRLanguageOption(id: "ru", displayName: "Russian", whisperCode: "ru"),
        ASRLanguageOption(id: "sa", displayName: "Sanskrit", whisperCode: "sa"),
        ASRLanguageOption(id: "sr", displayName: "Serbian", whisperCode: "sr"),
        ASRLanguageOption(id: "sn", displayName: "Shona", whisperCode: "sn"),
        ASRLanguageOption(id: "sd", displayName: "Sindhi", whisperCode: "sd"),
        ASRLanguageOption(id: "si", displayName: "Sinhala", whisperCode: "si"),
        ASRLanguageOption(id: "sk", displayName: "Slovak", whisperCode: "sk"),
        ASRLanguageOption(id: "sl", displayName: "Slovenian", whisperCode: "sl"),
        ASRLanguageOption(id: "so", displayName: "Somali", whisperCode: "so"),
        ASRLanguageOption(id: "su", displayName: "Sundanese", whisperCode: "su"),
        ASRLanguageOption(id: "sw", displayName: "Swahili", whisperCode: "sw"),
        ASRLanguageOption(id: "sv", displayName: "Swedish", whisperCode: "sv"),
        ASRLanguageOption(id: "tl", displayName: "Filipino / Tagalog", whisperCode: "tl"),
        ASRLanguageOption(id: "tg", displayName: "Tajik", whisperCode: "tg"),
        ASRLanguageOption(id: "ta", displayName: "Tamil", whisperCode: "ta"),
        ASRLanguageOption(id: "tt", displayName: "Tatar", whisperCode: "tt"),
        ASRLanguageOption(id: "te", displayName: "Telugu", whisperCode: "te"),
        ASRLanguageOption(id: "th", displayName: "Thai", whisperCode: "th"),
        ASRLanguageOption(id: "bo", displayName: "Tibetan", whisperCode: "bo"),
        ASRLanguageOption(id: "tr", displayName: "Turkish", whisperCode: "tr"),
        ASRLanguageOption(id: "tk", displayName: "Turkmen", whisperCode: "tk"),
        ASRLanguageOption(id: "uk", displayName: "Ukrainian", whisperCode: "uk"),
        ASRLanguageOption(id: "ur", displayName: "Urdu", whisperCode: "ur"),
        ASRLanguageOption(id: "uz", displayName: "Uzbek", whisperCode: "uz"),
        ASRLanguageOption(id: "vi", displayName: "Vietnamese", whisperCode: "vi"),
        ASRLanguageOption(id: "cy", displayName: "Welsh", whisperCode: "cy"),
        ASRLanguageOption(id: "yi", displayName: "Yiddish", whisperCode: "yi"),
        ASRLanguageOption(id: "yo", displayName: "Yoruba", whisperCode: "yo"),
    ]

    static var common: [ASRLanguageOption] {
        all.filter(\.isCommon).sorted { ($0.commonRank ?? .max) < ($1.commonRank ?? .max) }
    }

    static let qwenASRSupportedLanguageIDs = [
        "zh-CN", "zh-TW", "en-US", "yue", "ar", "de", "fr", "es",
        "pt", "id", "it", "ko", "ru", "th", "vi", "ja",
        "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl",
        "cs", "tl", "fa", "el", "hu", "mk", "ro",
    ]

    static var qwenASRSupportedLanguages: [ASRLanguageOption] {
        let supported = Set(qwenASRSupportedLanguageIDs)
        return all.filter { supported.contains($0.id) }
    }

    static func supportedOptions(forProvider provider: String) -> [ASRLanguageOption] {
        switch normalizedProvider(provider) {
        case "qwen3-asr-llama":
            return qwenASRSupportedLanguages
        default:
            return all
        }
    }

    static func commonOptions(forProvider provider: String) -> [ASRLanguageOption] {
        supportedOptions(forProvider: provider)
            .filter(\.isCommon)
            .sorted { ($0.commonRank ?? .max) < ($1.commonRank ?? .max) }
    }

    static func parse(_ rawValue: String) -> [String] {
        parse(rawValue, supportedOptions: all)
    }

    static func parse(_ rawValue: String, provider: String) -> [String] {
        parse(rawValue, supportedOptions: supportedOptions(forProvider: provider))
    }

    static func parse(_ rawValue: String, supportedOptions: [ASRLanguageOption]) -> [String] {
        let ids = rawValue
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\t" || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return validatedIDs(ids, supportedOptions: supportedOptions)
    }

    static func rawValue(for ids: [String]) -> String {
        validatedIDs(ids).joined(separator: ",")
    }

    static func rawValue(for ids: [String], supportedOptions: [ASRLanguageOption]) -> String {
        validatedIDs(ids, supportedOptions: supportedOptions).joined(separator: ",")
    }

    static func validatedIDs(_ ids: [String]) -> [String] {
        validatedIDs(ids, supportedOptions: all)
    }

    static func validatedIDs(_ ids: [String], provider: String) -> [String] {
        validatedIDs(ids, supportedOptions: supportedOptions(forProvider: provider))
    }

    static func validatedIDs(_ ids: [String], supportedOptions: [ASRLanguageOption]) -> [String] {
        let options = supportedOptions.isEmpty ? all : supportedOptions
        let canonical = Set(ids.compactMap(canonicalID(for:)))
        guard !canonical.isEmpty else { return defaultIDs(for: options) }
        let selected = options.map(\.id).filter { canonical.contains($0) }
        return selected.isEmpty ? defaultIDs(for: options) : selected
    }

    static func option(for id: String) -> ASRLanguageOption? {
        guard let canonical = canonicalID(for: id) else { return nil }
        return optionsByID[canonical]
    }

    static func displayNames(for ids: [String]) -> [String] {
        displayNames(for: ids, supportedOptions: all)
    }

    static func displayNames(for ids: [String], supportedOptions: [ASRLanguageOption]) -> [String] {
        let optionsByID = Dictionary(uniqueKeysWithValues: supportedOptions.map { ($0.id, $0) })
        return validatedIDs(ids, supportedOptions: supportedOptions).compactMap { optionsByID[$0]?.displayName }
    }

    static func whisperCodes(for ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in validatedIDs(ids) {
            guard let code = optionsByID[id]?.whisperCode, !seen.contains(code) else { continue }
            seen.insert(code)
            result.append(code)
        }
        return result
    }

    static func whisperLanguageHint(for ids: [String]) -> String? {
        let codes = whisperCodes(for: ids)
        return codes.count == 1 ? codes[0] : nil
    }

    static func scriptPreference(for ids: [String]) -> ChineseScriptPreference {
        let scripts = Set(validatedIDs(ids).compactMap { id -> ChineseScriptPreference? in
            guard let script = optionsByID[id]?.chineseScript, script != .preserve else { return nil }
            return script
        })
        if scripts == [.simplified] { return .simplified }
        if scripts == [.traditional] { return .traditional }
        return .preserve
    }

    static func primaryLanguageID(for ids: [String]) -> String {
        validatedIDs(ids).first ?? defaultIDs[0]
    }

    private static let optionsByID: [String: ASRLanguageOption] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    private static func defaultIDs(for supportedOptions: [ASRLanguageOption]) -> [String] {
        let supported = Set(supportedOptions.map(\.id))
        let defaults = defaultIDs.filter { supported.contains($0) }
        if !defaults.isEmpty { return defaults }
        return supportedOptions.first.map { [$0.id] } ?? defaultIDs
    }

    private static func normalizedProvider(_ provider: String) -> String {
        let value = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "qwen3-asr-llama":
            return "qwen3-asr-llama"
        default:
            return "whisperkit"
        }
    }

    private static func canonicalID(for rawID: String) -> String? {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        switch lower {
        case "auto":
            return nil
        case "zh", "zh-cn", "zh-hans", "zh-sg":
            return "zh-CN"
        case "zh-tw", "zh-hant", "zh-hk", "zh-mo":
            return "zh-TW"
        case "en", "en-us", "en-gb":
            return "en-US"
        case "fil":
            return "tl"
        default:
            return all.first {
                $0.id.lowercased() == lower ||
                    $0.whisperCode == lower
            }?.id
        }
    }
}

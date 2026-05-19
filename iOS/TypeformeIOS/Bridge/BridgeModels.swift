import Foundation

enum CorrectionModeID: String, CaseIterable, Identifiable, Codable {
    case clean
    case polish
    case polishPlus = "polish_plus"
    case structurePlus = "structure_plus"
    case formalPlus = "formal_plus"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: return "Clean"
        case .polish: return "Polish"
        case .polishPlus: return "Polish+"
        case .structurePlus: return "Structure+"
        case .formalPlus: return "Formal+"
        }
    }
}

enum NumberOutputPreferenceID: String, CaseIterable, Identifiable, Codable {
    case automatic = "auto"
    case digits
    case words

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Auto"
        case .digits: return "Digits"
        case .words: return "Words"
        }
    }

    static func normalized(_ raw: String?) -> NumberOutputPreferenceID {
        guard let raw,
              let value = NumberOutputPreferenceID(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        else { return .automatic }
        return value
    }
}

enum PunctuationPreferenceID: String, CaseIterable, Identifiable, Codable {
    case normal
    case english
    case spaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .english: return "English punctuation"
        case .spaces: return "Spaces"
        }
    }

    static func normalized(_ raw: String?) -> PunctuationPreferenceID {
        guard let raw,
              let value = PunctuationPreferenceID(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        else { return .normal }
        return value
    }
}

struct PairingConfig: Codable, Equatable {
    var lanBridgeURL: String
    var lanBridgeURLs: [String]
    var publicBridgeURL: String
    var token: String
    var languageIDs: [String]
    var supportedLanguages: [PairingLanguageOption]
    var correctionMode: CorrectionModeID

    static let empty = PairingConfig(
        lanBridgeURL: "",
        lanBridgeURLs: [],
        publicBridgeURL: "",
        token: "",
        languageIDs: ["zh-CN", "en-US"],
        supportedLanguages: PairingLanguageOption.allWhisperLanguages,
        correctionMode: .polish
    )

    enum CodingKeys: String, CodingKey {
        case lanBridgeURL = "lan_bridge_url"
        case lanBridgeURLs = "lan_bridge_urls"
        case publicBridgeURL = "public_bridge_url"
        case token
        case languageIDs = "language_ids"
        case supportedLanguages = "supported_languages"
        case correctionMode = "correction_mode"
    }

    init(
        lanBridgeURL: String,
        lanBridgeURLs: [String] = [],
        publicBridgeURL: String,
        token: String,
        languageIDs: [String],
        supportedLanguages: [PairingLanguageOption] = PairingLanguageOption.allWhisperLanguages,
        correctionMode: CorrectionModeID
    ) {
        let localCandidates = Self.uniqueBridgeURLs([lanBridgeURL] + lanBridgeURLs)
        self.lanBridgeURL = lanBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lanBridgeURLs = localCandidates
        self.publicBridgeURL = publicBridgeURL
        self.token = token
        self.languageIDs = languageIDs
        self.supportedLanguages = supportedLanguages
        self.correctionMode = correctionMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedLANBridgeURL = try container.decodeIfPresent(String.self, forKey: .lanBridgeURL) ?? ""
        let decodedLANBridgeURLs = try container.decodeIfPresent([String].self, forKey: .lanBridgeURLs) ?? []
        let localCandidates = Self.uniqueBridgeURLs([decodedLANBridgeURL] + decodedLANBridgeURLs)
        self.lanBridgeURL = decodedLANBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (localCandidates.first ?? "")
            : decodedLANBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lanBridgeURLs = localCandidates
        self.publicBridgeURL = try container.decodeIfPresent(String.self, forKey: .publicBridgeURL) ?? ""
        self.token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        self.supportedLanguages = try container.decodeIfPresent([PairingLanguageOption].self, forKey: .supportedLanguages)
            ?? PairingLanguageOption.allWhisperLanguages
        let decodedLanguageIDs = try container.decodeIfPresent([String].self, forKey: .languageIDs) ?? ["zh-CN", "en-US"]
        self.languageIDs = ASRLanguageSelection.validatedIDs(
            decodedLanguageIDs,
            supportedOptions: PairingLanguageOption.asASROptions(supportedLanguages)
        )
        self.correctionMode = try container.decodeIfPresent(CorrectionModeID.self, forKey: .correctionMode) ?? .polish
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lanBridgeURL, forKey: .lanBridgeURL)
        if !lanBridgeURLs.isEmpty {
            try container.encode(lanBridgeURLs, forKey: .lanBridgeURLs)
        }
        try container.encode(publicBridgeURL, forKey: .publicBridgeURL)
        try container.encode(token, forKey: .token)
        try container.encode(languageIDs, forKey: .languageIDs)
        try container.encode(supportedLanguages, forKey: .supportedLanguages)
        try container.encode(correctionMode, forKey: .correctionMode)
    }

    var hasAnyBridgeURL: Bool {
        !localBridgeURLCandidates.isEmpty ||
            !publicBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var localBridgeURLCandidates: [String] {
        Self.uniqueBridgeURLs([lanBridgeURL] + lanBridgeURLs)
    }

    var supportedLanguageOptions: [ASRLanguageOption] {
        PairingLanguageOption.asASROptions(supportedLanguages)
    }

    var validatedLanguageIDs: [String] {
        ASRLanguageSelection.validatedIDs(languageIDs, supportedOptions: supportedLanguageOptions)
    }

    mutating func normalizeLanguageIDs() {
        languageIDs = validatedLanguageIDs
    }

    mutating func promoteLocalBridgeURL(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = localBridgeURLCandidates
        lanBridgeURL = trimmed
        lanBridgeURLs = Self.uniqueBridgeURLs([trimmed] + existing)
    }

    static func uniqueBridgeURLs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var urls: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            urls.append(trimmed)
        }
        return urls
    }
}

struct PairingLanguageOption: Codable, Equatable, Identifiable {
    let id: String
    let displayName: String

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    init(_ option: ASRLanguageOption) {
        self.id = option.id
        self.displayName = option.displayName
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }

    static let allWhisperLanguages = ASRLanguageSelection.all.map(PairingLanguageOption.init)

    static func asASROptions(_ options: [PairingLanguageOption]) -> [ASRLanguageOption] {
        let resolved = options.compactMap { option -> ASRLanguageOption? in
            if let known = ASRLanguageSelection.option(for: option.id) {
                return known
            }
            let id = option.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return ASRLanguageOption(id: id, displayName: name, whisperCode: id)
        }
        return resolved.isEmpty ? ASRLanguageSelection.all : resolved
    }
}

struct BridgeHealthResponse: Decodable {
    let ok: Bool
    let service: String?
    let version: String?
}

struct BridgeSettingOption: Codable, Equatable, Identifiable {
    let id: String
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

struct BridgeModelStatus: Codable, Equatable, Identifiable {
    let id: String
    let kind: String
    let displayName: String
    let installed: Bool
    let installing: Bool
    let detail: String

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case displayName = "display_name"
        case installed
        case installing
        case detail
    }
}

struct BridgeMacSettingsPayload: Codable, Equatable {
    var asrProvider: String
    var asrProviderOptions: [BridgeSettingOption]
    var languageIDs: [String]
    var supportedLanguages: [PairingLanguageOption]
    var supportedLanguagesByASRProvider: [String: [PairingLanguageOption]]
    var asrTimeoutSec: Int
    var correctionBackend: String
    var correctionBackendOptions: [BridgeSettingOption]
    var correctionTimeoutMs: Int
    var correctionColdTimeoutMs: Int
    var correctionMode: CorrectionModeID
    var numberOutputPreference: NumberOutputPreferenceID
    var punctuationPreference: PunctuationPreferenceID
    var autoCommit: Bool
    var modelStatuses: [BridgeModelStatus]

    enum CodingKeys: String, CodingKey {
        case asrProvider = "asr_provider"
        case asrProviderOptions = "asr_provider_options"
        case languageIDs = "language_ids"
        case supportedLanguages = "supported_languages"
        case supportedLanguagesByASRProvider = "supported_languages_by_asr_provider"
        case asrTimeoutSec = "asr_timeout_sec"
        case correctionBackend = "correction_backend"
        case correctionBackendOptions = "correction_backend_options"
        case correctionTimeoutMs = "correction_timeout_ms"
        case correctionColdTimeoutMs = "correction_cold_timeout_ms"
        case correctionMode = "correction_mode"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case autoCommit = "auto_commit"
        case modelStatuses = "model_statuses"
    }

    init(
        asrProvider: String,
        asrProviderOptions: [BridgeSettingOption],
        languageIDs: [String],
        supportedLanguages: [PairingLanguageOption],
        supportedLanguagesByASRProvider: [String: [PairingLanguageOption]],
        asrTimeoutSec: Int = 120,
        correctionBackend: String,
        correctionBackendOptions: [BridgeSettingOption],
        correctionTimeoutMs: Int = 1500,
        correctionColdTimeoutMs: Int = 8000,
        correctionMode: CorrectionModeID,
        numberOutputPreference: NumberOutputPreferenceID = .automatic,
        punctuationPreference: PunctuationPreferenceID = .normal,
        autoCommit: Bool,
        modelStatuses: [BridgeModelStatus] = []
    ) {
        self.asrProvider = asrProvider
        self.asrProviderOptions = asrProviderOptions
        self.languageIDs = languageIDs
        self.supportedLanguages = supportedLanguages
        self.supportedLanguagesByASRProvider = supportedLanguagesByASRProvider
        self.asrTimeoutSec = min(max(asrTimeoutSec, 10), 300)
        self.correctionBackend = correctionBackend
        self.correctionBackendOptions = correctionBackendOptions
        self.correctionTimeoutMs = min(max(correctionTimeoutMs, 100), 30_000)
        self.correctionColdTimeoutMs = min(max(correctionColdTimeoutMs, 1_000), 60_000)
        self.correctionMode = correctionMode
        self.numberOutputPreference = numberOutputPreference
        self.punctuationPreference = punctuationPreference
        self.autoCommit = autoCommit
        self.modelStatuses = modelStatuses
        normalize()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.asrProvider = try container.decodeIfPresent(String.self, forKey: .asrProvider) ?? "qwen3-asr-llama"
        self.asrProviderOptions = try container.decodeIfPresent([BridgeSettingOption].self, forKey: .asrProviderOptions) ?? []
        self.supportedLanguages = try container.decodeIfPresent([PairingLanguageOption].self, forKey: .supportedLanguages)
            ?? PairingLanguageOption.allWhisperLanguages
        self.supportedLanguagesByASRProvider = try container.decodeIfPresent([String: [PairingLanguageOption]].self, forKey: .supportedLanguagesByASRProvider) ?? [:]
        self.languageIDs = try container.decodeIfPresent([String].self, forKey: .languageIDs) ?? ["zh-CN", "en-US"]
        self.asrTimeoutSec = try container.decodeIfPresent(Int.self, forKey: .asrTimeoutSec) ?? 120
        self.correctionBackend = try container.decodeIfPresent(String.self, forKey: .correctionBackend) ?? "qwen35_2b"
        self.correctionBackendOptions = try container.decodeIfPresent([BridgeSettingOption].self, forKey: .correctionBackendOptions) ?? []
        self.correctionTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .correctionTimeoutMs) ?? 1500
        self.correctionColdTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .correctionColdTimeoutMs) ?? 8000
        self.correctionMode = try container.decodeIfPresent(CorrectionModeID.self, forKey: .correctionMode) ?? .polish
        self.numberOutputPreference = try container.decodeIfPresent(NumberOutputPreferenceID.self, forKey: .numberOutputPreference) ?? .automatic
        self.punctuationPreference = try container.decodeIfPresent(PunctuationPreferenceID.self, forKey: .punctuationPreference) ?? .normal
        self.autoCommit = try container.decodeIfPresent(Bool.self, forKey: .autoCommit) ?? true
        self.modelStatuses = try container.decodeIfPresent([BridgeModelStatus].self, forKey: .modelStatuses) ?? []
        normalize()
    }

    mutating func normalize() {
        let supported = supportedLanguageOptions(for: asrProvider)
        languageIDs = ASRLanguageSelection.validatedIDs(languageIDs, supportedOptions: supported)
        asrTimeoutSec = min(max(asrTimeoutSec, 10), 300)
        correctionTimeoutMs = min(max(correctionTimeoutMs, 100), 30_000)
        correctionColdTimeoutMs = min(max(correctionColdTimeoutMs, 1_000), 60_000)
    }

    func supportedLanguageOptions(for provider: String) -> [ASRLanguageOption] {
        let options = supportedLanguagesByASRProvider[provider] ?? supportedLanguages
        return PairingLanguageOption.asASROptions(options)
    }
}

struct BridgeSettingsUpdateRequest: Encodable {
    let asrProvider: String
    let languageIDs: [String]
    let asrTimeoutSec: Int
    let correctionBackend: String
    let correctionTimeoutMs: Int
    let correctionColdTimeoutMs: Int
    let correctionMode: String
    let numberOutputPreference: String
    let punctuationPreference: String
    let autoCommit: Bool

    enum CodingKeys: String, CodingKey {
        case asrProvider = "asr_provider"
        case languageIDs = "language_ids"
        case asrTimeoutSec = "asr_timeout_sec"
        case correctionBackend = "correction_backend"
        case correctionTimeoutMs = "correction_timeout_ms"
        case correctionColdTimeoutMs = "correction_cold_timeout_ms"
        case correctionMode = "correction_mode"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case autoCommit = "auto_commit"
    }
}

struct BridgeDictateResponse: Decodable {
    let sessionID: String
    let text: String
    let correctionMode: String?
    let languageIDs: [String]
    let latencyMs: Int?
    let transcriptionLatencyMs: Int?
    let correctionLatencyMs: Int?
    let rawTranscript: String?
    let correctionStatus: String?
    let correctionError: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case text
        case correctionMode = "correction_mode"
        case languageIDs = "language_ids"
        case latencyMs = "latency_ms"
        case transcriptionLatencyMs = "transcription_latency_ms"
        case correctionLatencyMs = "correction_latency_ms"
        case rawTranscript = "raw_transcript"
        case correctionStatus = "correction_status"
        case correctionError = "correction_error"
    }
}

struct BridgeRestyleRequest: Encodable {
    let sessionID: String?
    let rawTranscript: String?
    let languageIDs: [String]
    let correctionMode: String
    let appName: String
    let appCategory: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case rawTranscript = "raw_transcript"
        case languageIDs = "language_ids"
        case correctionMode = "correction_mode"
        case appName = "app_name"
        case appCategory = "app_category"
    }
}

struct BridgeTextEditRequest: Encodable {
    let intent: String
    let contextBefore: String
    let targetText: String
    let contextAfter: String
    let spokenInstruction: String
    let languageIDs: [String]
    let appName: String
    let appCategory: String

    enum CodingKeys: String, CodingKey {
        case intent
        case contextBefore = "context_before"
        case targetText = "target_text"
        case contextAfter = "context_after"
        case spokenInstruction = "spoken_instruction"
        case languageIDs = "language_ids"
        case appName = "app_name"
        case appCategory = "app_category"
    }
}

struct BridgeRestyleResponse: Decodable {
    let sessionID: String
    let text: String
    let correctionMode: String?
    let languageIDs: [String]
    let latencyMs: Int?
    let correctionLatencyMs: Int?
    let correctionStatus: String?
    let correctionError: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case text
        case correctionMode = "correction_mode"
        case languageIDs = "language_ids"
        case latencyMs = "latency_ms"
        case correctionLatencyMs = "correction_latency_ms"
        case correctionStatus = "correction_status"
        case correctionError = "correction_error"
    }
}

struct BridgeTextEditResponse: Decodable {
    let text: String
    let action: String?
    let languageIDs: [String]
    let latencyMs: Int?
    let editLatencyMs: Int?
    let editStatus: String?
    let editError: String?

    enum CodingKeys: String, CodingKey {
        case text
        case action
        case languageIDs = "language_ids"
        case latencyMs = "latency_ms"
        case editLatencyMs = "edit_latency_ms"
        case editStatus = "edit_status"
        case editError = "edit_error"
    }
}

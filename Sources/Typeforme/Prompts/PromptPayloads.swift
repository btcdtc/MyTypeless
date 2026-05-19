import Foundation

struct PromptOutputPreferencesPayload: Codable, Sendable, Equatable {
    let numbers: String
    let numberInstruction: String
    let punctuation: String
    let punctuationInstruction: String

    enum CodingKeys: String, CodingKey {
        case numbers
        case numberInstruction = "number_instruction"
        case punctuation
        case punctuationInstruction = "punctuation_instruction"
    }
}

struct DictationPromptContextPayload: Codable, Sendable, Equatable {
    let appName: String
    let bundleID: String
    let appCategory: String
    let languages: [String]
    let languageCodes: [String]
    let whisperLanguageHint: String
    let languageInstruction: String
    let correctionMode: String
    let outputPreferences: PromptOutputPreferencesPayload

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case bundleID = "bundle_id"
        case appCategory = "app_category"
        case languages
        case languageCodes = "language_codes"
        case whisperLanguageHint = "whisper_language_hint"
        case languageInstruction = "language_instruction"
        case correctionMode = "correction_mode"
        case outputPreferences = "output_preferences"
    }
}

struct DictationPromptInputPayload: Codable, Sendable, Equatable {
    let task: String
    let commitScope: String
    let context: DictationPromptContextPayload
    let contextBefore: String
    let contextAfter: String
    let vocabularyCandidates: [VocabularyCandidatePayload]
    let rawTranscript: String

    enum CodingKeys: String, CodingKey {
        case task
        case commitScope = "commit_scope"
        case context
        case contextBefore = "context_before"
        case contextAfter = "context_after"
        case vocabularyCandidates = "vocabulary_candidates"
        case rawTranscript = "raw_transcript"
    }
}

struct TextEditPromptContextPayload: Codable, Sendable, Equatable {
    let appName: String
    let bundleID: String
    let appCategory: String
    let languages: [String]
    let languageCodes: [String]
    let languageInstruction: String
    let targetLanguageHint: String
    let outputPreferences: PromptOutputPreferencesPayload

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case bundleID = "bundle_id"
        case appCategory = "app_category"
        case languages
        case languageCodes = "language_codes"
        case languageInstruction = "language_instruction"
        case targetLanguageHint = "target_language_hint"
        case outputPreferences = "output_preferences"
    }
}

struct TextEditPromptInputPayload: Codable, Sendable, Equatable {
    let task: String
    let intent: String
    let context: TextEditPromptContextPayload
    let vocabularyCandidates: [VocabularyCandidatePayload]
    let contextBefore: String
    let targetText: String
    let contextAfter: String
    let spokenInstruction: String

    enum CodingKeys: String, CodingKey {
        case task
        case intent
        case context
        case vocabularyCandidates = "vocabulary_candidates"
        case contextBefore = "context_before"
        case targetText = "target_text"
        case contextAfter = "context_after"
        case spokenInstruction = "spoken_instruction"
    }
}

enum PromptPayloadEncoder {
    static func jsonString<T: Encodable>(_ payload: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

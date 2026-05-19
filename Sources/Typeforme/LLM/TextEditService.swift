import Foundation

@MainActor
final class TextEditService {
    private let dictionary: UserDictionaryStore

    init(dictionary: UserDictionaryStore) {
        self.dictionary = dictionary
    }

    func edit(
        intent: TextEditIntent,
        contextBefore: String,
        targetText: String,
        contextAfter: String,
        spokenInstruction: String,
        languageIDs: [String],
        appName: String?,
        bundleID: String?,
        appCategory: AppCategory
    ) async throws -> TextEditResult {
        let request = TextEditRequest(
            intent: intent,
            contextBefore: contextBefore,
            targetText: targetText,
            contextAfter: contextAfter,
            spokenInstruction: spokenInstruction,
            languageIDs: languageIDs,
            frontmostAppName: appName,
            frontmostBundleID: bundleID,
            appCategory: appCategory,
            numberOutputPreference: AppSettings.numberOutputPreference,
            punctuationPreference: AppSettings.punctuationPreference,
            userDictionary: dictionary.sortedSnapshot()
        )
        let (system, user) = TextEditPromptBuilder.build(for: request)
        let output = try await CorrectorFactory.shared.make().complete(
            system: system,
            user: user,
            timeoutMs: AppSettings.correctionTimeoutMs
        )
        var result = try TextEditValidator.parseAndValidate(rawOutput: output, for: request)
        result.text = LocaleTextNormalizer.normalize(result.text, languageIDs: languageIDs)
        result.text = TranscriptPostProcessor.clean(
            result.text,
            languageIDs: languageIDs,
            preserveLineBreaks: true,
            appendTerminalPunctuation: false,
            numberPreference: AppSettings.numberOutputPreference,
            punctuationPreference: AppSettings.punctuationPreference
        )
        return result
    }
}

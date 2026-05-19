import Foundation

struct CorrectionRequest: Codable, Sendable {
    var correctionMode: CorrectionMode
    var frontmostAppName: String?
    var frontmostBundleID: String?
    var appCategory: AppCategory
    var languageIDs: [String]
    var rawTranscript: String
    var contextBefore: String
    var contextAfter: String
    var numberOutputPreference: NumberOutputPreference
    var punctuationPreference: PunctuationOutputPreference
    var userDictionary: [DictionaryEntry]

    init(
        correctionMode: CorrectionMode,
        frontmostAppName: String?,
        frontmostBundleID: String?,
        appCategory: AppCategory,
        languageIDs: [String],
        rawTranscript: String,
        contextBefore: String = "",
        contextAfter: String = "",
        numberOutputPreference: NumberOutputPreference = .automatic,
        punctuationPreference: PunctuationOutputPreference = .normal,
        userDictionary: [DictionaryEntry]
    ) {
        self.correctionMode = correctionMode
        self.frontmostAppName = frontmostAppName
        self.frontmostBundleID = frontmostBundleID
        self.appCategory = appCategory
        self.languageIDs = languageIDs
        self.rawTranscript = rawTranscript
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.numberOutputPreference = numberOutputPreference
        self.punctuationPreference = punctuationPreference
        self.userDictionary = userDictionary
    }

    func replacingCorrectionMode(_ correctionMode: CorrectionMode) -> CorrectionRequest {
        CorrectionRequest(
            correctionMode: correctionMode,
            frontmostAppName: frontmostAppName,
            frontmostBundleID: frontmostBundleID,
            appCategory: appCategory,
            languageIDs: languageIDs,
            rawTranscript: rawTranscript,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            numberOutputPreference: numberOutputPreference,
            punctuationPreference: punctuationPreference,
            userDictionary: userDictionary
        )
    }
}

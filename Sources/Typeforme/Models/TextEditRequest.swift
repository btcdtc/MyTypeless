import Foundation

enum TextEditIntent: String, Codable, Sendable {
    case repairSelection = "repair_selection"
    case command = "command"
}

enum TextEditAction: String, Codable, Sendable {
    case replaceTarget = "replace_target"
}

struct TextEditRequest: Sendable {
    var intent: TextEditIntent
    var contextBefore: String
    var targetText: String
    var contextAfter: String
    var spokenInstruction: String
    var languageIDs: [String]
    var frontmostAppName: String?
    var frontmostBundleID: String?
    var appCategory: AppCategory
    var numberOutputPreference: NumberOutputPreference
    var punctuationPreference: PunctuationOutputPreference
    var userDictionary: [DictionaryEntry]

    init(
        intent: TextEditIntent,
        contextBefore: String,
        targetText: String,
        contextAfter: String,
        spokenInstruction: String,
        languageIDs: [String],
        frontmostAppName: String?,
        frontmostBundleID: String?,
        appCategory: AppCategory,
        numberOutputPreference: NumberOutputPreference = .automatic,
        punctuationPreference: PunctuationOutputPreference = .normal,
        userDictionary: [DictionaryEntry]
    ) {
        self.intent = intent
        self.contextBefore = contextBefore
        self.targetText = targetText
        self.contextAfter = contextAfter
        self.spokenInstruction = spokenInstruction
        self.languageIDs = languageIDs
        self.frontmostAppName = frontmostAppName
        self.frontmostBundleID = frontmostBundleID
        self.appCategory = appCategory
        self.numberOutputPreference = numberOutputPreference
        self.punctuationPreference = punctuationPreference
        self.userDictionary = userDictionary
    }
}

struct TextEditResult: Sendable {
    var action: TextEditAction
    var text: String
}

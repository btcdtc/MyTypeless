import Testing
@testable import Typeforme

@Suite("LocaleTextNormalizer")
struct LocaleTextNormalizerTests {
    @Test func simplifiedChineseNormalizesTraditionalCharacters() {
        let text = LocaleTextNormalizer.normalize("這是一個測試，語音輸入", locale: "zh-CN")
        #expect(text == "这是一个测试，语音输入")
    }

    @Test func traditionalChineseNormalizesSimplifiedCharacters() {
        let text = LocaleTextNormalizer.normalize("这是一个测试，语音输入", locale: "zh-TW")
        #expect(text == "這是一個測試，語音輸入")
    }

    @Test func autoPreservesMixedLanguageText() {
        let text = "今天 ship 这个 feature"
        #expect(LocaleTextNormalizer.normalize(text, languageIDs: ["en-US", "ja"]) == text)
    }

    @Test func mixedSimplifiedChineseNormalizesChineseOnly() {
        let text = LocaleTextNormalizer.normalize("今天 ship 這個 feature", languageIDs: ["zh-CN", "en-US"])
        #expect(text == "今天 ship 这个 feature")
    }

    @Test func simplifiedChineseDoesNotCorruptJapaneseKanji() {
        let text = LocaleTextNormalizer.normalize("この機能は便利だけど UI が少し重い", languageIDs: ["zh-CN", "ja"])
        #expect(text == "この機能は便利だけど UI が少し重い")
    }

    @Test func mixedChineseAndJapaneseNormalizesOnlyChineseRuns() {
        let text = LocaleTextNormalizer.normalize("這個功能很好 この機能を見て", languageIDs: ["zh-CN", "ja"])
        #expect(text == "这个功能很好 この機能を見て")
    }

    @Test func promptInstructionPreservesSelectedLanguageSegments() {
        let prompt = LocaleTextNormalizer.promptInstruction(for: ["vi", "zh-CN"])
        #expect(prompt.contains("do not translate between selected languages"))
        #expect(prompt.contains("Preserve natural code-switching"))
        #expect(prompt.contains("preserve language-specific diacritics"))
        #expect(prompt.contains("avoid archaic, literary, or word-for-word calques"))
    }
}

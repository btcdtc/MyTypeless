import Testing
@testable import Typeforme

@Suite("ASRLanguageSelection")
struct ASRLanguageSelectionTests {
    @Test func exposesWhisperLanguageCatalog() {
        #expect(ASRLanguageSelection.all.count >= 95)
        #expect(Set(ASRLanguageSelection.all.map(\.id)).count == ASRLanguageSelection.all.count)
        #expect(ASRLanguageSelection.option(for: "yue")?.displayName == "Cantonese")
    }

    @Test func singleLanguageProducesWhisperHint() {
        #expect(ASRLanguageSelection.whisperLanguageHint(for: ["zh-CN"]) == "zh")
        #expect(ASRLanguageSelection.whisperLanguageHint(for: ["en-US"]) == "en")
        #expect(ASRLanguageSelection.whisperLanguageHint(for: ["ja"]) == "ja")
    }

    @Test func multipleLanguagesUseDetection() {
        #expect(ASRLanguageSelection.whisperLanguageHint(for: ["zh-CN", "en-US"]) == nil)
        #expect(ASRLanguageSelection.whisperCodes(for: ["zh-CN", "en-US"]) == ["zh", "en"])
    }

    @Test func compatibilityLanguageValuesAreCanonicalized() {
        #expect(ASRLanguageSelection.parse("zh-Hant") == ["zh-TW"])
        #expect(ASRLanguageSelection.parse("en") == ["en-US"])
        #expect(ASRLanguageSelection.parse("fil") == ["tl"])
        #expect(ASRLanguageSelection.parse("auto") == ASRLanguageSelection.defaultIDs)
    }

    @Test func qwenASRLanguageCatalogMatchesSupportedModelList() {
        let ids = Set(ASRLanguageSelection.qwenASRSupportedLanguages.map(\.id))
        #expect(ids.contains("vi"))
        #expect(ids.contains("tl"))
        #expect(ids.contains("ro"))
        #expect(!ids.contains("af"))
        #expect(ASRLanguageSelection.validatedIDs(["af", "vi"], provider: "qwen3-asr-llama") == ["vi"])
    }
}

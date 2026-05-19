import Foundation
import Testing
@testable import Typeforme

@Suite("ASRAudioSupport")
struct ASRAudioSupportTests {
    @Test func stripsQwenASRTranscriptMarkers() {
        let text = "language English<asr_text>Hello, world.</asr_text>"
        #expect(ASRAudioSupport.cleanTranscriptText(text) == "Hello, world.")
    }

    @Test func parsesLlamaChatASRResponse() throws {
        let data = #"{"choices":[{"message":{"role":"assistant","content":"language Chinese<asr_text>你好，世界。</asr_text>"}}]}"#.data(using: .utf8)!
        #expect(try QwenLlamaASRService.parseChatTranscript(data: data) == "你好，世界。")
    }

    @Test func parsesLlamaChatASRContentArrayResponse() throws {
        let data = #"{"choices":[{"message":{"role":"assistant","content":[{"type":"text","text":"language Chinese<asr_text>你好，世界。</asr_text>"}]}}]}"#.data(using: .utf8)!
        #expect(try QwenLlamaASRService.parseChatTranscript(data: data) == "你好，世界。")
    }

    @Test func qwenPromptKeepsMixedLanguagesAndScript() {
        let prompt = QwenLlamaASRService.transcriptionPrompt(languageIDs: ["zh-CN", "en-US"])
        #expect(prompt.contains("Chinese (Simplified), English"))
        #expect(prompt.contains("Transcribe every audible sentence"))
        #expect(prompt.contains("do not summarize"))
        #expect(prompt.contains("Preserve mixed-language speech"))
        #expect(prompt.contains("Use Simplified Chinese"))
    }

    @Test func qwenPromptProtectsDiacriticsAndShortWordsWithoutLanguageRules() {
        let prompt = QwenLlamaASRService.transcriptionPrompt(languageIDs: ["zh-CN", "en-US", "vi"])
        #expect(prompt.contains("Vietnamese"))
        #expect(prompt.contains("Preserve audible diacritics, tones, accents"))
        #expect(prompt.contains("Do not expand a short word into a longer phrase"))
        #expect(!prompt.contains("keo/kéo"))
    }

    @Test func qwenRetriesOnlyTransientASRErrors() {
        #expect(QwenLlamaASRService.shouldRetryTransientASRError(ASRAudioSupportError.emptyTranscript, attempt: 1))
        #expect(QwenLlamaASRService.shouldRetryTransientASRError(ASRAudioSupportError.httpStatus(503, "busy"), attempt: 1))
        #expect(QwenLlamaASRService.shouldRetryTransientASRError(URLError(.networkConnectionLost), attempt: 1))

        #expect(!QwenLlamaASRService.shouldRetryTransientASRError(ASRAudioSupportError.emptyTranscript, attempt: 2))
        #expect(!QwenLlamaASRService.shouldRetryTransientASRError(ASRAudioSupportError.timeout(seconds: 120), attempt: 1))
        #expect(!QwenLlamaASRService.shouldRetryTransientASRError(ASRAudioSupportError.audioConversionFailed("bad audio"), attempt: 1))
        #expect(!QwenLlamaASRService.shouldRetryTransientASRError(ASRAudioSupportError.httpStatus(400, "bad request"), attempt: 1))
    }
}

import Testing
@testable import Typeforme

@Suite("ProtectedSpanPostProcessor")
struct ProtectedSpanPostProcessorTests {
    @Test func restoresLeadingCodeSwitchSpan() {
        let output = ProtectedSpanPostProcessor.apply(
            "你好，今天测试一下越南语和中文混合输入，不要翻译。",
            rawTranscript: "xin chào 今天测试一下越南语和中文混合输入，不要翻译。"
        )
        #expect(output == "xin chào，今天测试一下越南语和中文混合输入，不要翻译。")
    }

    @Test func ignoresLeadingFillers() {
        let output = ProtectedSpanPostProcessor.apply(
            "今天测试一下。",
            rawTranscript: "um 今天测试一下。"
        )
        #expect(output == "今天测试一下。")
    }

    @Test func rejectsTranslatedOutputWhenUserSaidNotToTranslate() {
        let output = ProtectedSpanPostProcessor.apply(
            "Xin chào, hôm nay thử nghiệm đầu vào hỗn hợp tiếng Việt và tiếng Trung, không dịch.",
            rawTranscript: "xin chào 今天测试一下越南语和中文混合输入，不要翻译。"
        )
        #expect(output == "xin chào 今天测试一下越南语和中文混合输入，不要翻译。")
    }

    @Test func rejectsLatinScriptSentenceTranslatedToChinese() {
        let output = ProtectedSpanPostProcessor.apply(
            "这是什么广播？",
            rawTranscript: "bộ phát thanh là cây kéo gì?"
        )
        #expect(output == "bộ phát thanh là cây kéo gì?")
    }

    @Test func restoresProtectedPathToken() {
        let output = ProtectedSpanPostProcessor.apply(
            "- URL: https://example.com/api/v1\n- 检查路径: /users。",
            rawTranscript: "打开 https://example.com/api/v1，然后看一下 /users 这个 path 有没有问题。"
        )
        #expect(output.contains("检查path"))
    }

    @Test func rejectsOutputThatTranslatedProtectedTechnicalTokens() {
        let output = ProtectedSpanPostProcessor.apply(
            "今日已将该功能发布至生产环境，但尚未编写发布说明，暂勿合并。",
            rawTranscript: "今天把这个 feature ship 到 prod，但是 release note 还没写，先不要 merge。"
        )
        #expect(output == "今天把这个 feature ship 到 prod，但是 release note 还没写，先不要 merge。")
    }

    @Test func restoresMissingSupermarketInStructuredOutput() {
        let output = ProtectedSpanPostProcessor.apply(
            "让我试试这个新的APP好不好用？\n- 要买：菠萝、苹果、香蕉\n- 时间：三点，哦不对，是四点。",
            rawTranscript: "让我试试这个新的APP好不好用？比如说，今天我要买菠萝、苹果、香蕉，要在超市三哦，不对，是四点去超市买。"
        )
        #expect(output.contains("\n- 地点：超市"))
    }

    @Test func rejectsTranslationExecutionWhenMarkerDisappears() {
        let output = ProtectedSpanPostProcessor.apply(
            "你好。",
            rawTranscript: "把 hello 翻译成中文。"
        )
        #expect(output == "把 hello 翻译成中文。")
    }

    @Test func keepsTranscriptWhenTranslationMarkerStillPresent() {
        let output = ProtectedSpanPostProcessor.apply(
            "请把 hello 翻译成中文。",
            rawTranscript: "请把 hello 翻译成中文。"
        )
        #expect(output == "请把 hello 翻译成中文。")
    }
}

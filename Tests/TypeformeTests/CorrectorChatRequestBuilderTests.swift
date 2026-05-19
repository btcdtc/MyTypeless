import Foundation
import Testing
@testable import Typeforme

@Suite("CorrectorChatRequestBuilder")
struct CorrectorChatRequestBuilderTests {
    @Test func addsDeterministicCorrectionSamplingOptions() throws {
        let body = CorrectorChatRequestBuilder.body(
            model: "qwen3.6-27b",
            system: "system",
            user: "user",
            maxTokens: 128
        )

        #expect(body.temperature == 0.2)
        #expect(body.topP == 0.8)
        #expect(body.topK == 20)
        #expect(body.minP == 0.0)
        #expect(body.presencePenalty == 0.0)
        #expect(body.repeatPenalty == 1.0)
        #expect(body.repetitionPenalty == 1.0)
        #expect(body.maxTokens == 128)
        #expect(body.stream == false)
    }

    @Test func encodesOpenAICompatibleSnakeCaseKeys() throws {
        let body = CorrectorChatRequestBuilder.body(
            model: "qwen3.6-27b",
            system: "system",
            user: "user",
            maxTokens: 128
        )
        let data = try JSONEncoder().encode(body)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["top_p"] as? Double == 0.8)
        #expect(object["top_k"] as? Int == 20)
        #expect(object["min_p"] as? Double == 0.0)
        #expect(object["repeat_penalty"] as? Double == 1.0)
        #expect(object["repetition_penalty"] as? Double == 1.0)
        #expect(object["max_tokens"] as? Int == 128)
        #expect((object["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
    }

    @Test func addsQwenNoThinkHints() throws {
        let body = CorrectorChatRequestBuilder.body(
            model: "qwen3.6-27b",
            system: "system",
            user: "user",
            maxTokens: 128
        )
        let kwargs = try #require(body.chatTemplateKwargs)

        #expect(body.messages[1].content.contains("/no_think"))
        #expect(body.messages.last?.content == QwenPromptHints.noThinkAssistantPrefill)
        #expect(kwargs.enableThinking == false)
    }

    @Test func doesNotAddQwenSpecificHintsForOtherModels() throws {
        let body = CorrectorChatRequestBuilder.body(
            model: "llama-3.1",
            system: "system",
            user: "user",
            maxTokens: 128
        )
        #expect(body.messages.count == 2)
        #expect(body.messages[1].content == "user")
        #expect(body.chatTemplateKwargs == nil)
    }
}

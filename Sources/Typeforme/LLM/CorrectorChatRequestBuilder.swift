import Foundation

enum CorrectorChatRequestBuilder {
    static let temperature: Double = 0.2
    static let topP: Double = 0.8
    static let topK = 20
    static let minP: Double = 0.0
    static let presencePenalty: Double = 0.0
    static let repetitionPenalty: Double = 1.0

    static func body(
        model: String,
        system: String,
        user: String,
        maxTokens: Int
    ) -> OpenAIChatCompletionRequest {
        let messages = QwenPromptHints
            .openAIChatMessages(system: system, user: user, model: model)
            .map { message in
                OpenAIChatMessage(
                    role: message["role"] ?? "user",
                    content: message["content"] ?? ""
                )
            }
        let templateKwargs = QwenPromptHints.prefersNoThink(model: model)
            ? OpenAIChatTemplateKwargs(enableThinking: false)
            : nil
        return OpenAIChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: temperature,
            topP: topP,
            topK: topK,
            minP: minP,
            presencePenalty: presencePenalty,
            repeatPenalty: repetitionPenalty,
            repetitionPenalty: repetitionPenalty,
            maxTokens: maxTokens,
            stream: false,
            chatTemplateKwargs: templateKwargs
        )
    }
}

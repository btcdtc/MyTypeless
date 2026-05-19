import Foundation

enum QwenPromptHints {
    static let noThinkAssistantPrefill = "<think>\n\n</think>\n\n"

    static func prefersNoThink(model: String) -> Bool {
        let lowercased = model.lowercased()
        return lowercased.contains("qwen") || lowercased.contains("qwq")
    }

    static func userPrompt(_ prompt: String, model: String) -> String {
        guard prefersNoThink(model: model) else { return prompt }
        if prompt.contains("/no_think") || prompt.contains("/think") {
            return prompt
        }
        return prompt + "\n/no_think"
    }

    static func openAIChatMessages(system: String, user: String, model: String) -> [[String: String]] {
        var messages = [
            ["role": "system", "content": system],
            ["role": "user", "content": userPrompt(user, model: model)],
        ]
        if prefersNoThink(model: model) {
            messages.append(["role": "assistant", "content": noThinkAssistantPrefill])
        }
        return messages
    }
}

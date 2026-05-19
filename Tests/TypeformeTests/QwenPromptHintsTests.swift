import Foundation
import Testing
@testable import Typeforme

@Suite("QwenPromptHints")
struct QwenPromptHintsTests {
    @Test func qwenUserPromptGetsNoThinkHint() {
        #expect(QwenPromptHints.userPrompt("Fix text", model: "qwen/qwen3-35b-a3b").hasSuffix("/no_think"))
        #expect(QwenPromptHints.userPrompt("Fix text", model: "mlx-community/gemma-3").contains("/no_think") == false)
        #expect(QwenPromptHints.userPrompt("Fix text\n/no_think", model: "Qwen3").filter { $0 == "/" }.count == 1)
    }

    @Test func qwenChatMessagesUseAssistantNoThinkPrefill() {
        let messages = QwenPromptHints.openAIChatMessages(system: "system", user: "user", model: "qwen3.6-35b-a3b")
        #expect(messages.count == 3)
        #expect(messages[0]["role"] == "system")
        #expect(messages[1]["content"]?.hasSuffix("/no_think") == true)
        #expect(messages[2]["role"] == "assistant")
        #expect(messages[2]["content"] == QwenPromptHints.noThinkAssistantPrefill)
    }
}

import Testing
@testable import Typeforme

/// Spec §18 — cleaning + JSON extraction.
@Suite("ModelOutputCleaner")
struct ModelOutputCleanerTests {

    @Test func stripsThinkBlock() {
        let input = "<think>internal reasoning</think>\nfinal answer"
        #expect(ModelOutputCleaner.clean(input) == "final answer")
    }

    @Test func stripsMultilineThinkBlock() {
        let input = "<think>\nlots\nof\nlines\n</think>\nfinal"
        #expect(ModelOutputCleaner.clean(input) == "final")
    }

    @Test func stripsCodeFences() {
        let input = "```json\n{\"a\":1}\n```"
        let cleaned = ModelOutputCleaner.clean(input)
        #expect(cleaned.contains("\"a\":1"))
        #expect(!cleaned.contains("```"))
    }

    @Test func extractsBalancedJSON() {
        let input = "noise {\"action\":\"commit\",\"text\":\"hi\",\"risk\":\"low\"} more noise"
        let extracted = ModelOutputCleaner.extractFirstJSONObject(input)
        #expect(extracted == "{\"action\":\"commit\",\"text\":\"hi\",\"risk\":\"low\"}")
    }

    @Test func extractsJSONWithNestedBraces() {
        let input = "{\"a\":{\"b\":1},\"c\":2}"
        #expect(ModelOutputCleaner.extractFirstJSONObject(input) == input)
    }

    @Test func extractsJSONWithEscapedQuotes() {
        let input = "{\"text\":\"a \\\"quoted\\\" word\"}"
        #expect(ModelOutputCleaner.extractFirstJSONObject(input) == input)
    }

    @Test func extractsJSONIgnoresBraceInsideString() {
        // The closing } inside the quoted string must not end the object.
        let input = "{\"text\":\"see this } here\",\"x\":1}"
        #expect(ModelOutputCleaner.extractFirstJSONObject(input) == input)
    }

    @Test func returnsNilWhenNoObject() {
        #expect(ModelOutputCleaner.extractFirstJSONObject("just text") == nil)
    }
}

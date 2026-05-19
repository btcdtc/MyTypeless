import Testing
@testable import Typeforme

@Suite("VocabularyCandidateSelector")
struct VocabularyCandidateSelectorTests {
    @Test func selectsPersonByPhoneticConfusion() {
        let entries = [
            DictionaryEntry(type: "person", surface: "方圆"),
            DictionaryEntry(type: "project", surface: "Apollo"),
        ]

        let result = VocabularyCandidateSelector.select(
            from: entries,
            rawText: "我刚刚和方元确认了这个 bug"
        )

        #expect(result.map(\.surface) == ["方圆"])
    }

    @Test func selectsChineseHomophoneByPinyin() {
        let entries = [
            DictionaryEntry(type: "person", surface: "方圆"),
        ]

        let result = VocabularyCandidateSelector.select(
            from: entries,
            rawText: "这个问题要问一下方元"
        )

        #expect(result.first?.surface == "方圆")
    }

    @Test func selectsChineseNearPhoneticCandidate() {
        let entries = [
            DictionaryEntry(type: "person", surface: "张山"),
        ]

        let result = VocabularyCandidateSelector.select(
            from: entries,
            rawText: "找脏山确认一下"
        )

        #expect(result.first?.surface == "张山")
    }

    @Test func selectsSpokenEnglishAcronym() {
        let entries = [
            DictionaryEntry(type: "acronym", surface: "CLI"),
        ]

        let result = VocabularyCandidateSelector.select(
            from: entries,
            rawText: "run the see ell eye command"
        )

        #expect(result.first?.surface == "CLI")
    }

    @Test func selectsEnglishPhoneticCandidate() {
        let entries = [
            DictionaryEntry(type: "product", surface: "Grafana"),
        ]

        let result = VocabularyCandidateSelector.select(
            from: entries,
            rawText: "check the graphana dashboard"
        )

        #expect(result.first?.surface == "Grafana")
    }

    @Test func textContextReranksMatchedCandidatesButDoesNotSummonUnmatchedTerms() {
        let ambiguous = [
            DictionaryEntry(type: "person", surface: "Apollo"),
            DictionaryEntry(type: "project", surface: "Apollo"),
        ]

        let projectResult = VocabularyCandidateSelector.select(
            from: ambiguous,
            rawText: "Apollo issue PR release"
        )
        #expect(projectResult.first?.type == "project")

        let personResult = VocabularyCandidateSelector.select(
            from: ambiguous,
            rawText: "ask Apollo to confirm"
        )
        #expect(personResult.first?.type == "person")

        let unrelated = VocabularyCandidateSelector.select(
            from: [DictionaryEntry(type: "technical_term", surface: "GraphRAG")],
            rawText: "server latency is high"
        )
        #expect(unrelated.isEmpty)
    }

    @Test func promptPayloadUsesVocabularyCandidateShape() {
        let entries = [
            DictionaryEntry(type: "person", surface: "方圆"),
        ]

        let payload = VocabularyCandidateSelector.promptPayload(
            from: entries,
            rawText: "和方元对一下"
        )

        #expect(payload.count == 1)
        #expect(payload[0].type == "person")
        #expect(payload[0].surface == "方圆")
        let json = PromptPayloadEncoder.jsonString(payload) ?? ""
        #expect(!json.contains("spoken_forms"))
        #expect(!json.contains("common_confusions"))
        #expect(!json.contains("priority"))
    }

    @Test func doesNotReturnUnrelatedLargeVocabularyItems() {
        let entries = (0..<100).map {
            DictionaryEntry(type: "person", surface: "测试用户\($0)")
        }

        let result = VocabularyCandidateSelector.select(
            from: entries,
            rawText: "今天讨论 server latency"
        )

        #expect(result.isEmpty)
    }
}

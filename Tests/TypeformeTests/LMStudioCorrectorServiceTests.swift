import Foundation
import Testing
@testable import Typeforme

@Suite("LMStudioCorrectorService")
struct LMStudioCorrectorServiceTests {
    @Test func buildsChatCompletionsEndpointFromRootOrV1Base() throws {
        #expect(try LMStudioCorrectorService.chatCompletionsEndpoint(baseURL: "http://localhost:1234").absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(try LMStudioCorrectorService.chatCompletionsEndpoint(baseURL: "http://localhost:1234/v1").absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(try LMStudioCorrectorService.chatCompletionsEndpoint(baseURL: "http://localhost:1234/v1/chat/completions").absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(try LMStudioCorrectorService.chatCompletionsEndpoint(baseURL: "http://192.0.2.10:1234/v1").absoluteString == "http://192.0.2.10:1234/v1/chat/completions")
        #expect(try LMStudioCorrectorService.chatCompletionsEndpoint(baseURL: "https://lmstudio.example.com/v1").absoluteString == "https://lmstudio.example.com/v1/chat/completions")
    }

    @Test func buildsModelsEndpointFromChatEndpoint() throws {
        #expect(try LMStudioCorrectorService.modelsEndpoint(baseURL: "http://localhost:1234/v1/chat/completions").absoluteString == "http://localhost:1234/v1/models")
        #expect(try LMStudioCorrectorService.modelsEndpoint(baseURL: "http://192.0.2.10:1234/v1/chat/completions").absoluteString == "http://192.0.2.10:1234/v1/models")
    }

    @Test func rejectsNonHTTPBaseURL() {
        #expect(throws: (any Error).self) {
            _ = try LMStudioCorrectorService.chatCompletionsEndpoint(baseURL: "file:///tmp/lmstudio")
        }
    }

    @Test func parsesModelIDsFromModelsResponse() throws {
        let data = #"{"data":[{"id":"qwen/qwen3-35b-a3b"},{"id":"  "},{"id":"mlx-community/Qwen3-4B"}]}"#
            .data(using: .utf8)!
        #expect(LMStudioCorrectorService.modelIDs(data: data) == [
            "qwen/qwen3-35b-a3b",
            "mlx-community/Qwen3-4B",
        ])
    }

    @Test func enforcesLMStudioMinimumTimeout() {
        #expect(LMStudioCorrectorService.effectiveTimeoutMs(1500) == LMStudioCorrectorService.minimumRequestTimeoutMs)
        #expect(LMStudioCorrectorService.effectiveTimeoutMs(45_000) == 45_000)
    }

    @Test func selectsFirstAvailableModelWhenCurrentDisappears() {
        #expect(LMStudioCorrectorService.modelSelectionAfterRefresh(
            current: "qwen3.5-old",
            available: ["qwen3.6-27b", "qwen3.5-9b"],
            selectFirstModel: false
        ) == "qwen3.6-27b")
    }

    @Test func preservesAvailableModelAfterRefresh() {
        #expect(LMStudioCorrectorService.modelSelectionAfterRefresh(
            current: " qwen3.5-9b ",
            available: ["qwen3.6-27b", "qwen3.5-9b"],
            selectFirstModel: false
        ) == "qwen3.5-9b")
    }

    @Test func onlySelectsFirstForEmptyModelWhenRequested() {
        #expect(LMStudioCorrectorService.modelSelectionAfterRefresh(
            current: "",
            available: ["qwen3.6-27b"],
            selectFirstModel: false
        ) == "")
        #expect(LMStudioCorrectorService.modelSelectionAfterRefresh(
            current: "",
            available: ["qwen3.6-27b"],
            selectFirstModel: true
        ) == "qwen3.6-27b")
    }
}

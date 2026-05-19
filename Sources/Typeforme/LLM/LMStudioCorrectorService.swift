import Foundation

struct LMStudioCheckReport: Sendable {
    let ok: Bool
    let status: String
    let detail: String
    let modelIDs: [String]
}

final class LMStudioCorrectorService: CorrectorService {
    let kind: CorrectionBackendKind = .externalLMStudio

    static let minimumRequestTimeoutMs = 30_000

    func correct(_ request: CorrectionRequest, timeoutMs: Int) async throws -> CorrectionResult {
        let (system, user) = PromptBuilder.build(for: request)
        let content = try await complete(system: system, user: user, timeoutMs: timeoutMs)
        do {
            var result = try CorrectionValidator.parseAndValidate(rawOutput: content, for: request)
            result.text = ProtectedSpanPostProcessor.apply(result.text, rawTranscript: request.rawTranscript)
            result.text = TranscriptPostProcessor.clean(
                result.text,
                languageIDs: request.languageIDs,
                preserveLineBreaks: request.correctionMode == .structurePlus,
                numberPreference: request.numberOutputPreference,
                punctuationPreference: request.punctuationPreference
            )
            return result
        } catch let error as CorrectionValidationError {
            throw CorrectorError.validationFailed(error.localizedDescription)
        }
    }

    func complete(system: String, user: String, timeoutMs: Int) async throws -> String {
        let model = AppSettings.lmStudioModel
        guard !model.isEmpty else {
            throw CorrectorError.unavailable("Set the LM Studio model identifier in Settings")
        }

        let endpoint = try Self.chatCompletionsEndpoint(baseURL: AppSettings.lmStudioBaseURL)

        let body = CorrectorChatRequestBuilder.body(
            model: model,
            system: system,
            user: user,
            maxTokens: AppSettings.correctionMaxTokens
        )
        let requestTimeoutMs = Self.effectiveTimeoutMs(timeoutMs)
        do {
            return try await OpenAICompatibleClient.chatCompletionContent(
                endpoint: endpoint,
                request: body,
                apiKey: AppSettings.lmStudioAPIKey,
                timeoutMs: requestTimeoutMs
            )
        } catch let error as OpenAICompatibleClientError {
            throw error.correctorError
        }
    }

    static func effectiveTimeoutMs(_ configuredTimeoutMs: Int) -> Int {
        max(configuredTimeoutMs, minimumRequestTimeoutMs)
    }

    static func checkConfiguration() async -> LMStudioCheckReport {
        do {
            let endpoint = try modelsEndpoint(baseURL: AppSettings.lmStudioBaseURL)

            let modelIDs = try await OpenAICompatibleClient.modelIDs(
                endpoint: endpoint,
                apiKey: AppSettings.lmStudioAPIKey,
                timeout: 5
            )
            return LMStudioCheckReport(
                ok: true,
                status: "Ready",
                detail: modelListSummary(modelIDs: modelIDs),
                modelIDs: modelIDs
            )
        } catch {
            return LMStudioCheckReport(ok: false, status: "Failed", detail: error.localizedDescription, modelIDs: [])
        }
    }

    static func chatCompletionsEndpoint(baseURL: String) throws -> URL {
        let normalized = normalizedBaseURLString(baseURL)
        guard !normalized.isEmpty else {
            throw CorrectorError.unavailable("LM Studio URL is empty")
        }
        if normalized.hasSuffix("/chat/completions") {
            guard let url = URL(string: normalized) else { throw CorrectorError.unavailable("Invalid LM Studio URL") }
            try validateHTTPURL(url)
            return url
        }
        let path = normalized.hasSuffix("/v1") ? "/chat/completions" : "/v1/chat/completions"
        guard let url = URL(string: normalized + path) else {
            throw CorrectorError.unavailable("Invalid LM Studio URL")
        }
        try validateHTTPURL(url)
        return url
    }

    static func modelsEndpoint(baseURL: String) throws -> URL {
        var normalized = normalizedBaseURLString(baseURL)
        guard !normalized.isEmpty else {
            throw CorrectorError.unavailable("LM Studio URL is empty")
        }
        if normalized.hasSuffix("/chat/completions") {
            normalized = String(normalized.dropLast("/chat/completions".count))
        }
        let path = normalized.hasSuffix("/v1") ? "/models" : "/v1/models"
        guard let url = URL(string: normalized + path) else {
            throw CorrectorError.unavailable("Invalid LM Studio URL")
        }
        try validateHTTPURL(url)
        return url
    }

    private static func validateHTTPURL(_ url: URL) throws {
        guard
            let scheme = url.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            url.host != nil
        else {
            throw CorrectorError.unavailable("LM Studio URL must be an http or https URL")
        }
    }

    static func modelIDs(data: Data) -> [String] {
        OpenAICompatibleClient.modelIDs(data: data)
    }

    static func modelSelectionAfterRefresh(
        current: String,
        available: [String],
        selectFirstModel: Bool
    ) -> String {
        let trimmedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = available.first else {
            return trimmedCurrent
        }
        guard !trimmedCurrent.isEmpty else {
            return selectFirstModel ? first : trimmedCurrent
        }
        return available.contains(trimmedCurrent) ? trimmedCurrent : first
    }

    private static func modelListSummary(modelIDs: [String]) -> String {
        guard !modelIDs.isEmpty else { return "Server responded to /v1/models, but no model IDs were listed." }
        let preview = modelIDs.prefix(4).joined(separator: ", ")
        return modelIDs.count > 4 ? "\(modelIDs.count) models: \(preview), ..." : "\(modelIDs.count) models: \(preview)"
    }

    private static func normalizedBaseURLString(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

import Foundation

/// Sends OpenAI-compatible chat-completion requests to the local llama-server.
/// On cold start `LlamaCppServerManager.ensureRunning` may take the configured
/// cold timeout; the actual chat call uses the configured request timeout.
final class EmbeddedLlamaCorrectorService: CorrectorService {
    let kind: CorrectionBackendKind
    private let server: LlamaCppServerManager

    init(kind: CorrectionBackendKind, server: LlamaCppServerManager) {
        self.kind = kind
        self.server = server
    }

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
        // Warmup uses the cold-timeout window from settings.
        let port: Int
        do {
            port = try await server.ensureRunning()
        } catch {
            throw CorrectorError.unavailable(error.localizedDescription)
        }

        let body = CorrectorChatRequestBuilder.body(
            model: "qwen3.5",
            system: system,
            user: user,
            maxTokens: AppSettings.correctionMaxTokens
        )
        do {
            return try await OpenAICompatibleClient.chatCompletionContent(
                endpoint: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
                request: body,
                timeoutMs: timeoutMs
            ) { [server] in
                await server.stop()
            }
        } catch let error as OpenAICompatibleClientError {
            throw error.correctorError
        }
    }
}

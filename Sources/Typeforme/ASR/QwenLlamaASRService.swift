import Foundation

final class QwenLlamaASRService: ASRService {
    static let maxTransientASRAttempts = 2

    private let server: LlamaCppServerManager

    init(server: LlamaCppServerManager) {
        self.server = server
    }

    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        let supportedLanguageIDs = ASRLanguageSelection.validatedIDs(
            languageIDs,
            supportedOptions: ASRLanguageSelection.qwenASRSupportedLanguages
        )
        let port: Int
        do {
            port = try await server.ensureRunning()
        } catch {
            throw ASRAudioSupportError.httpStatus(503, error.localizedDescription)
        }
        let text = try await Self.transcribeViaLlamaChatWithRetry(
            audioFileURL: audioFileURL,
            languageIDs: supportedLanguageIDs,
            port: port,
            timeout: AppSettings.asrQwenLlamaTimeoutSeconds,
            maxTokens: AppSettings.asrQwenLlamaMaxTokens,
            model: (AppSettings.asrQwenLlamaModelPath as NSString).lastPathComponent
        )
        return text
    }

    static func shouldRetryTransientASRError(_ error: Error, attempt: Int) -> Bool {
        guard attempt < maxTransientASRAttempts else { return false }
        if let asrError = error as? ASRAudioSupportError {
            switch asrError {
            case .emptyTranscript:
                return true
            case .httpStatus(let code, _):
                return code >= 500 && code < 600
            case .audioConversionFailed, .requestBodyFailed, .timeout, .unsupportedBridgeAudioExtension:
                return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .cannotConnectToHost, .timedOut:
                return true
            default:
                return false
            }
        }
        return false
    }

    func preload() async throws {
        _ = try await server.ensureRunning()
    }

    func stop() async {
        await server.stop()
    }

    static func chatCompletionsEndpoint(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
    }

    static func transcriptionPrompt(languageIDs: [String]) -> String {
        let names = ASRLanguageSelection.displayNames(
            for: languageIDs,
            supportedOptions: ASRLanguageSelection.qwenASRSupportedLanguages
        )
        let languageClause = names.isEmpty
            ? "Detect the spoken language."
            : "The expected spoken languages may include: \(names.joined(separator: ", "))."
        let scriptClause: String
        switch ASRLanguageSelection.scriptPreference(for: languageIDs) {
        case .simplified:
            scriptClause = "Use Simplified Chinese for Chinese text."
        case .traditional:
            scriptClause = "Use Traditional Chinese for Chinese text."
        case .preserve:
            scriptClause = "Preserve the spoken script when it is clear."
        }
        return [
            "Transcribe every audible sentence in the audio in order.",
            "This is speech-to-text only: do not summarize, rewrite, translate, answer, or infer the speaker's intent.",
            "Do not stop after the first sentence.",
            "Keep repeated words, fillers, false starts, and self-corrections when audible; a later cleanup step will edit them.",
            languageClause,
            "Preserve mixed-language speech instead of translating it.",
            "Preserve audible diacritics, tones, accents, and short content words. Do not expand a short word into a longer phrase unless the extra words are clearly audible.",
            scriptClause,
            "Use light punctuation when it is clear from the speech.",
            "Output only the transcript."
        ].joined(separator: " ")
    }

    static func parseChatTranscript(data: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(QwenASRChatResponse.self, from: data) else {
            return ASRAudioSupport.cleanTranscriptText(
                String(data: data, encoding: .utf8) ?? ""
            )
        }
        if let text = response.extractedText {
            return ASRAudioSupport.cleanTranscriptText(text)
        }
        return ""
    }

    private static func responseSummary(data: Data) -> String {
        guard let response = try? JSONDecoder().decode(QwenASRChatResponse.self, from: data) else {
            return "non_json bytes=\(data.count)"
        }

        var parts = ["bytes=\(data.count)"]
        if let choices = response.choices {
            parts.append("choices=\(choices.count)")
            if let first = choices.first, let finishReason = first.finishReason {
                parts.append("finish_reason=\(finishReason)")
            }
            if let content = choices.first?.message?.content {
                parts.append("message_content=\(content.summary)")
            }
        } else {
            parts.append("choices=nil")
        }
        if let message = response.error?.message.prefix(160) {
            parts.append("error=\(message)")
        }
        return parts.joined(separator: " ")
    }

    private static func transcribeViaLlamaChat(
        audioFileURL: URL,
        languageIDs: [String],
        port: Int,
        timeout: TimeInterval,
        maxTokens: Int,
        model: String
    ) async throws -> String {
        let uploadURL = try await ASRAudioSupport.llamaUploadableAudioURL(for: audioFileURL)
        defer {
            if uploadURL != audioFileURL {
                try? FileManager.default.removeItem(at: uploadURL)
            }
        }

        let audioBase64: String
        do {
            audioBase64 = try Data(contentsOf: uploadURL).base64EncodedString()
        } catch {
            throw ASRAudioSupportError.requestBodyFailed(error.localizedDescription)
        }

        let endpoint = chatCompletionsEndpoint(port: port)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = QwenASRChatRequest(
            model: model.isEmpty ? "qwen3-asr" : model,
            messages: [
                .init(
                    role: "user",
                    content: [
                        .text(transcriptionPrompt(languageIDs: languageIDs)),
                        .inputAudio(data: audioBase64, format: "wav")
                    ]
                )
            ],
            temperature: 0,
            maxTokens: maxTokens,
            stream: false
        )

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw ASRAudioSupportError.requestBodyFailed(error.localizedDescription)
        }

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        try ASRAudioSupport.validateHTTPResponse(response, data: data)
        let text = try parseChatTranscript(data: data)
        guard !text.isEmpty else {
            Log.asr.notice("qwen3-asr empty transcript response: \(responseSummary(data: data), privacy: .public)")
            throw ASRAudioSupportError.emptyTranscript
        }
        return LocaleTextNormalizer.normalize(text, languageIDs: languageIDs)
    }

    private static func transcribeViaLlamaChatWithRetry(
        audioFileURL: URL,
        languageIDs: [String],
        port: Int,
        timeout: TimeInterval,
        maxTokens: Int,
        model: String
    ) async throws -> String {
        var lastError: Error?
        for attempt in 1...maxTransientASRAttempts {
            do {
                return try await transcribeViaLlamaChat(
                    audioFileURL: audioFileURL,
                    languageIDs: languageIDs,
                    port: port,
                    timeout: timeout,
                    maxTokens: maxTokens,
                    model: model
                )
            } catch {
                lastError = error
                guard shouldRetryTransientASRError(error, attempt: attempt) else {
                    throw error
                }
                Log.asr.notice("qwen3-asr transient failure on attempt \(attempt, privacy: .public); retrying: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        throw lastError ?? ASRAudioSupportError.emptyTranscript
    }
}

private struct QwenASRChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: [ContentPart]
    }

    enum ContentPart: Encodable {
        case text(String)
        case inputAudio(data: String, format: String)

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case inputAudio = "input_audio"
        }

        enum AudioCodingKeys: String, CodingKey {
            case data
            case format
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .inputAudio(let data, let format):
                try container.encode("input_audio", forKey: .type)
                var audio = container.nestedContainer(keyedBy: AudioCodingKeys.self, forKey: .inputAudio)
                try audio.encode(data, forKey: .data)
                try audio.encode(format, forKey: .format)
            }
        }
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
    }
}

private struct QwenASRChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: ResponseContent?
        }

        let message: Message?
        let text: String?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case text
            case finishReason = "finish_reason"
        }
    }

    struct ErrorPayload: Decodable {
        let message: String
    }

    let choices: [Choice]?
    let text: String?
    let content: ResponseContent?
    let error: ErrorPayload?

    var extractedText: String? {
        if let choices, let first = choices.first {
            if let text = first.message?.content?.text { return text }
            if let text = first.text { return text }
        }
        if let text { return text }
        return content?.text
    }
}

private enum ResponseContent: Decodable {
    case string(String)
    case object(ResponseContentItem)
    case array([ResponseContentItem])

    var text: String? {
        switch self {
        case .string(let text):
            return text
        case .object(let item):
            return item.textValue
        case .array(let items):
            let text = items.compactMap(\.textValue).joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
    }

    var summary: String {
        switch self {
        case .string(let text):
            return "string(\(text.count))"
        case .object:
            return "object"
        case .array(let items):
            return "array(\(items.count))"
        }
    }

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let text = try? singleValue.decode(String.self) {
            self = .string(text)
            return
        }
        if let items = try? singleValue.decode([ResponseContentItem].self) {
            self = .array(items)
            return
        }
        self = .object(try singleValue.decode(ResponseContentItem.self))
    }
}

private struct ResponseContentItem: Decodable {
    let text: String?
    let content: String?
    let inputText: String?

    enum CodingKeys: String, CodingKey {
        case text
        case content
        case inputText = "input_text"
    }

    var textValue: String? {
        if let text { return text }
        if let content { return content }
        return inputText
    }
}

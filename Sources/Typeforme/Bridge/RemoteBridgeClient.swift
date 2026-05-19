import Foundation

enum RemoteBridgeClientError: LocalizedError {
    case missingURL
    case missingToken
    case invalidURL
    case unauthorizedOrUnavailable
    case invalidResponse
    case server(String)
    case correctionFailed(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .missingURL:
            return "Client Bridge URL is empty"
        case .missingToken:
            return "Client Bridge token is empty"
        case .invalidURL:
            return "Client Bridge URL is invalid"
        case .unauthorizedOrUnavailable:
            return "Client Bridge unavailable or token rejected"
        case .invalidResponse:
            return "Client Bridge returned an invalid response"
        case .server(let message):
            return message
        case .correctionFailed(let message):
            return message.isEmpty ? "Remote correction failed" : message
        case .emptyResult:
            return "Remote Bridge returned an empty result"
        }
    }
}

private struct RemoteBridgeRestyleRequest: Encodable {
    let sessionID: String?
    let rawTranscript: String?
    let languageIDs: [String]
    let correctionMode: String
    let appName: String?
    let bundleID: String?
    let appCategory: String
    let contextBefore: String?
    let contextAfter: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case rawTranscript = "raw_transcript"
        case languageIDs = "language_ids"
        case correctionMode = "correction_mode"
        case appName = "app_name"
        case bundleID = "bundle_id"
        case appCategory = "app_category"
        case contextBefore = "context_before"
        case contextAfter = "context_after"
    }
}

private struct RemoteBridgeTextEditRequest: Encodable {
    let intent: String
    let contextBefore: String
    let targetText: String
    let contextAfter: String
    let spokenInstruction: String
    let languageIDs: [String]
    let appName: String?
    let bundleID: String?
    let appCategory: String

    enum CodingKeys: String, CodingKey {
        case intent
        case contextBefore = "context_before"
        case targetText = "target_text"
        case contextAfter = "context_after"
        case spokenInstruction = "spoken_instruction"
        case languageIDs = "language_ids"
        case appName = "app_name"
        case bundleID = "bundle_id"
        case appCategory = "app_category"
    }
}

private struct RemoteBridgeSettingsUpdateRequest: Encodable {
    let asrProvider: String
    let languageIDs: [String]
    let asrTimeoutSec: Int
    let correctionBackend: String
    let correctionTimeoutMs: Int
    let correctionColdTimeoutMs: Int
    let lmStudioBaseURL: String?
    let lmStudioModel: String?
    let correctionMode: String
    let numberOutputPreference: String
    let punctuationPreference: String
    let autoCommit: Bool
    let debugMode: Bool

    enum CodingKeys: String, CodingKey {
        case asrProvider = "asr_provider"
        case languageIDs = "language_ids"
        case asrTimeoutSec = "asr_timeout_sec"
        case correctionBackend = "correction_backend"
        case correctionTimeoutMs = "correction_timeout_ms"
        case correctionColdTimeoutMs = "correction_cold_timeout_ms"
        case lmStudioBaseURL = "lm_studio_base_url"
        case lmStudioModel = "lm_studio_model"
        case correctionMode = "correction_mode"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case autoCommit = "auto_commit"
        case debugMode = "debug_mode"
    }
}

struct RemoteBridgeClient {
    let baseURL: URL
    let token: String

    init(baseURLString: String, token: String) throws {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { throw RemoteBridgeClientError.missingURL }
        guard !trimmedToken.isEmpty else { throw RemoteBridgeClientError.missingToken }

        let normalized = Self.normalizedBaseURL(trimmedURL)
        guard let url = URL(string: normalized), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw RemoteBridgeClientError.invalidURL
        }
        self.baseURL = url
        self.token = trimmedToken
    }

    static func resolvedFromSettings(
        probeAllEndpoints: Bool = false
    ) async throws -> (client: RemoteBridgeClient, routeStatus: ClientBridgeRouteStatus) {
        let config = ClientBridgeConfiguration.current
        guard config.hasAnyBridgeURL else { throw RemoteBridgeClientError.missingURL }
        guard !config.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteBridgeClientError.missingToken
        }

        let status = await ClientBridgeRouteResolver().resolve(
            config: config,
            probeAllEndpoints: probeAllEndpoints
        )
        guard let activeURL = status.activeURL else {
            throw RemoteBridgeClientError.unauthorizedOrUnavailable
        }
        return (
            try RemoteBridgeClient(baseURLString: activeURL.absoluteString, token: config.token),
            status
        )
    }

    func health(timeout: TimeInterval = 4) async throws -> BridgeHealthResponse {
        try await request(
            path: "/v1/health",
            method: "GET",
            body: Optional<Data>.none,
            timeout: timeout
        )
    }

    func settings(timeout: TimeInterval = 10) async throws -> BridgeSettingsPayload {
        var response: BridgeSettingsPayload = try await request(
            path: "/v1/settings",
            method: "GET",
            body: Optional<Data>.none,
            timeout: timeout
        )
        response.normalize()
        return response
    }

    func updateSettings(
        _ settings: BridgeSettingsPayload,
        timeout: TimeInterval = 15
    ) async throws -> BridgeSettingsPayload {
        let payload = RemoteBridgeSettingsUpdateRequest(
            asrProvider: settings.asrProvider,
            languageIDs: settings.languageIDs,
            asrTimeoutSec: settings.asrTimeoutSec,
            correctionBackend: settings.correctionBackend,
            correctionTimeoutMs: settings.correctionTimeoutMs,
            correctionColdTimeoutMs: settings.correctionColdTimeoutMs,
            lmStudioBaseURL: settings.lmStudioBaseURL,
            lmStudioModel: settings.lmStudioModel,
            correctionMode: settings.correctionMode,
            numberOutputPreference: settings.numberOutputPreference,
            punctuationPreference: settings.punctuationPreference,
            autoCommit: settings.autoCommit,
            debugMode: settings.debugMode
        )
        var response: BridgeSettingsPayload = try await request(
            path: "/v1/settings",
            method: "POST",
            json: payload,
            timeout: timeout
        )
        response.normalize()
        return response
    }

    func dictate(
        audioURL: URL,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        appSnapshot: FrontmostAppSnapshot?,
        appCategory: AppCategory,
        contextBefore: String = "",
        contextAfter: String = "",
        includeRawTranscript: Bool = true
    ) async throws -> BridgeDictateResponse {
        let uploadURL = try ASRAudioSupport.bridgeUploadAudioURL(for: audioURL)
        let multipart = try Self.multipartDictateBody(
            audioURL: uploadURL,
            languageIDs: languageIDs,
            correctionMode: correctionMode.rawValue,
            appName: appSnapshot?.localizedName,
            bundleID: appSnapshot?.bundleID,
            appCategory: appCategory.rawValue,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            includeRawTranscript: includeRawTranscript
        )
        let response: BridgeDictateResponse = try await request(
            path: "/v1/dictate",
            method: "POST",
            body: multipart.body,
            contentType: multipart.contentType,
            timeout: 90
        )
        try validate(response)
        return response
    }

    func restyle(
        sessionID: String?,
        rawTranscript: String?,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        appSnapshot: FrontmostAppSnapshot?,
        appCategory: AppCategory,
        contextBefore: String = "",
        contextAfter: String = ""
    ) async throws -> BridgeRestyleResponse {
        let payload = RemoteBridgeRestyleRequest(
            sessionID: sessionID,
            rawTranscript: rawTranscript,
            languageIDs: languageIDs,
            correctionMode: correctionMode.rawValue,
            appName: appSnapshot?.localizedName,
            bundleID: appSnapshot?.bundleID,
            appCategory: appCategory.rawValue,
            contextBefore: contextBefore,
            contextAfter: contextAfter
        )
        let response: BridgeRestyleResponse = try await request(
            path: "/v1/restyle",
            method: "POST",
            json: payload,
            timeout: 45
        )
        try validate(response)
        return response
    }

    func editText(
        intent: TextEditIntent,
        contextBefore: String,
        targetText: String,
        contextAfter: String,
        spokenInstruction: String,
        languageIDs: [String],
        appSnapshot: FrontmostAppSnapshot?,
        appCategory: AppCategory
    ) async throws -> BridgeTextEditResponse {
        let payload = RemoteBridgeTextEditRequest(
            intent: intent.rawValue,
            contextBefore: contextBefore,
            targetText: targetText,
            contextAfter: contextAfter,
            spokenInstruction: spokenInstruction,
            languageIDs: languageIDs,
            appName: appSnapshot?.localizedName,
            bundleID: appSnapshot?.bundleID,
            appCategory: appCategory.rawValue
        )
        let response: BridgeTextEditResponse = try await request(
            path: "/v1/edit-text",
            method: "POST",
            json: payload,
            timeout: 45
        )
        try validate(response)
        return response
    }

    private static func normalizedBaseURL(_ raw: String) -> String {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return raw
        }
        if raw.hasPrefix("localhost")
            || raw.hasPrefix("127.")
            || raw.hasPrefix("192.168.")
            || raw.hasPrefix("10.")
            || raw.range(of: #"^172\.(1[6-9]|2[0-9]|3[0-1])\."#, options: .regularExpression) != nil
            || raw.contains(":") {
            return "http://\(raw)"
        }
        return "https://\(raw)"
    }

    private func validate(_ response: BridgeDictateResponse) throws {
        if response.correctionStatus == "error" {
            throw RemoteBridgeClientError.correctionFailed(response.correctionError ?? "")
        }
        if response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RemoteBridgeClientError.emptyResult
        }
    }

    private func validate(_ response: BridgeRestyleResponse) throws {
        if response.correctionStatus == "error" {
            throw RemoteBridgeClientError.correctionFailed(response.correctionError ?? "")
        }
        if response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RemoteBridgeClientError.emptyResult
        }
    }

    private func validate(_ response: BridgeTextEditResponse) throws {
        if response.editStatus == "error" {
            throw RemoteBridgeClientError.correctionFailed(response.editError ?? "")
        }
        if response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RemoteBridgeClientError.emptyResult
        }
    }

    private func request<T: Decodable, Body: Encodable>(
        path: String,
        method: String,
        json body: Body,
        timeout: TimeInterval
    ) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await request(path: path, method: method, body: data, contentType: "application/json", timeout: timeout)
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        body: Data?,
        contentType: String? = nil,
        timeout: TimeInterval
    ) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw RemoteBridgeClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteBridgeClientError.invalidResponse
        }
        guard http.statusCode != 401 && http.statusCode != 403 && http.statusCode != 404 else {
            throw RemoteBridgeClientError.unauthorizedOrUnavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(BridgeErrorResponse.self, from: data).error)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw RemoteBridgeClientError.server(message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RemoteBridgeClientError.invalidResponse
        }
    }

    static func multipartDictateBody(
        audioURL: URL,
        languageIDs: [String],
        correctionMode: String,
        appName: String?,
        bundleID: String?,
        appCategory: String,
        contextBefore: String = "",
        contextAfter: String = "",
        includeRawTranscript: Bool
    ) throws -> (body: Data, contentType: String) {
        let multipart = try BridgeMultipart.dictateBody(
            audioURL: audioURL,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            includeRawTranscript: includeRawTranscript
        )
        return (multipart.body, multipart.contentType)
    }
}

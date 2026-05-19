import Foundation

enum BridgeClientError: LocalizedError {
    case invalidURL
    case unauthorizedOrUnavailable
    case invalidResponse
    case server(String)
    case unsupportedAudioFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid bridge URL"
        case .unauthorizedOrUnavailable:
            return "Bridge unavailable or token rejected"
        case .invalidResponse:
            return "Bridge returned an invalid response"
        case .server(let message):
            return message
        case .unsupportedAudioFormat(let detail):
            return "Bridge upload audio must be M4A/AAC; got \(detail)"
        }
    }
}

private struct BridgeErrorResponse: Decodable {
    let error: String
}

struct BridgeClient {
    let baseURL: URL
    let token: String

    init?(baseURLString: String, token: String) {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        self.baseURL = url
        self.token = token
    }

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    func health(timeout: TimeInterval = 2.5) async -> Bool {
        do {
            let response: BridgeHealthResponse = try await request(
                path: "/v1/health",
                method: "GET",
                body: Optional<Data>.none,
                timeout: timeout
            )
            return response.ok
        } catch {
            return false
        }
    }

    func pairing(timeout: TimeInterval = 10) async throws -> PairingConfig {
        try await request(
            path: "/v1/pairing",
            method: "GET",
            body: Optional<Data>.none,
            timeout: timeout
        )
    }

    func macSettings(timeout: TimeInterval = 10) async throws -> BridgeMacSettingsPayload {
        try await request(
            path: "/v1/settings",
            method: "GET",
            body: Optional<Data>.none,
            timeout: timeout
        )
    }

    func updateMacSettings(
        _ settings: BridgeMacSettingsPayload,
        timeout: TimeInterval = 15
    ) async throws -> BridgeMacSettingsPayload {
        let payload = BridgeSettingsUpdateRequest(
            asrProvider: settings.asrProvider,
            languageIDs: settings.languageIDs,
            asrTimeoutSec: settings.asrTimeoutSec,
            correctionBackend: settings.correctionBackend,
            correctionTimeoutMs: settings.correctionTimeoutMs,
            correctionColdTimeoutMs: settings.correctionColdTimeoutMs,
            correctionMode: settings.correctionMode.rawValue,
            numberOutputPreference: settings.numberOutputPreference.rawValue,
            punctuationPreference: settings.punctuationPreference.rawValue,
            autoCommit: settings.autoCommit
        )
        return try await request(path: "/v1/settings", method: "POST", json: payload, timeout: timeout)
    }

    func dictate(
        audioURL: URL,
        audioExtension: String,
        languageIDs: [String],
        correctionMode: CorrectionModeID,
        contextBefore: String = "",
        contextAfter: String = "",
        includeRawTranscript: Bool
    ) async throws -> BridgeDictateResponse {
        let ext = (audioURL.pathExtension.isEmpty ? audioExtension : audioURL.pathExtension).lowercased()
        guard ["m4a", "aac"].contains(ext) else {
            throw BridgeClientError.unsupportedAudioFormat(ext.isEmpty ? "missing extension" : ext)
        }
        let multipart = try Self.multipartDictateBody(
            audioURL: audioURL,
            audioExtension: ext,
            languageIDs: languageIDs,
            correctionMode: correctionMode.rawValue,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            includeRawTranscript: includeRawTranscript
        )
        return try await request(
            path: "/v1/dictate",
            method: "POST",
            body: multipart.body,
            contentType: multipart.contentType,
            timeout: 45
        )
    }

    func restyle(
        sessionID: String?,
        rawTranscript: String?,
        languageIDs: [String],
        correctionMode: CorrectionModeID
    ) async throws -> BridgeRestyleResponse {
        let payload = BridgeRestyleRequest(
            sessionID: sessionID,
            rawTranscript: rawTranscript,
            languageIDs: languageIDs,
            correctionMode: correctionMode.rawValue,
            appName: "iOS",
            appCategory: "chat"
        )
        return try await request(path: "/v1/restyle", method: "POST", json: payload, timeout: 20)
    }

    func editText(
        intent: String,
        contextBefore: String,
        targetText: String,
        contextAfter: String,
        spokenInstruction: String,
        languageIDs: [String]
    ) async throws -> BridgeTextEditResponse {
        let payload = BridgeTextEditRequest(
            intent: intent,
            contextBefore: contextBefore,
            targetText: targetText,
            contextAfter: contextAfter,
            spokenInstruction: spokenInstruction,
            languageIDs: languageIDs,
            appName: "iOS",
            appCategory: "chat"
        )
        return try await request(path: "/v1/edit-text", method: "POST", json: payload, timeout: 30)
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
            throw BridgeClientError.invalidURL
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
            throw BridgeClientError.invalidResponse
        }
        guard http.statusCode != 401 && http.statusCode != 403 && http.statusCode != 404 else {
            throw BridgeClientError.unauthorizedOrUnavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(BridgeErrorResponse.self, from: data).error)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw BridgeClientError.server(message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func multipartDictateBody(
        audioURL: URL,
        audioExtension: String,
        languageIDs: [String],
        correctionMode: String,
        contextBefore: String,
        contextAfter: String,
        includeRawTranscript: Bool
    ) throws -> (body: Data, contentType: String) {
        let multipart = try BridgeMultipart.dictateBody(
            audioURL: audioURL,
            audioExtension: audioExtension,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: "iOS",
            appCategory: "chat",
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            includeRawTranscript: includeRawTranscript
        )
        return (multipart.body, multipart.contentType)
    }

}

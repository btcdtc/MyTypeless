import Foundation
import Hummingbird

final class BridgeHTTPServer: @unchecked Sendable {
    private let service: BridgeService
    private let stateLock = NSLock()
    private var serverTask: Task<Void, Never>?
    private var activePort: Int?
    private var activeHost: String?
    private var activeRunID: UUID?
    private var running = false

    private static let maxBodyBytes = 25 * 1024 * 1024
    private static let maxMultipartHeaderBytes = 16 * 1024
    private static let maxMultipartFieldBytes = 1 * 1024 * 1024

    @MainActor
    init(dictionary: UserDictionaryStore) {
        service = BridgeService(dictionary: dictionary)
    }

    func applySettings() {
        guard AppSettings.bridgeEnabled else {
            stop()
            return
        }

        let port = AppSettings.bridgePort
        let host = Self.bindHost()
        let current = stateSnapshot()
        if current.running, current.port == port, current.host == host { return }
        stop()
        start(host: host, port: port)
    }

    func stop() {
        let task: Task<Void, Never>?
        stateLock.lock()
        task = serverTask
        serverTask = nil
        activePort = nil
        activeHost = nil
        activeRunID = nil
        running = false
        stateLock.unlock()

        task?.cancel()
        if task != nil {
            Log.app.info("Bridge stopping")
        }
    }

    static func constantTimeEquals(_ supplied: String, _ expected: String) -> Bool {
        let suppliedBytes = Array(supplied.utf8)
        let expectedBytes = Array(expected.utf8)
        var diff = suppliedBytes.count ^ expectedBytes.count
        let count = max(suppliedBytes.count, expectedBytes.count)
        for i in 0..<count {
            let suppliedByte = i < suppliedBytes.count ? suppliedBytes[i] : 0
            let expectedByte = i < expectedBytes.count ? expectedBytes[i] : 0
            diff |= Int(suppliedByte ^ expectedByte)
        }
        return diff == 0
    }

    private func stateSnapshot() -> (running: Bool, port: Int?, host: String?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (running, activePort, activeHost)
    }

    private static func bindHost() -> String {
        AppSettings.bridgeLANEnabled ? "0.0.0.0" : "127.0.0.1"
    }

    private func start(host: String, port: Int) {
        let runID = UUID()
        let app = makeApplication(host: host, port: port)
        let task = Task.detached(priority: .utility) { [weak self] in
            defer {
                self?.markStopped(runID: runID)
            }
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch is CancellationError {
                Log.app.info("Bridge stopped")
            } catch {
                Log.app.error("Bridge server failed: \(error.localizedDescription)")
            }
        }

        stateLock.lock()
        serverTask = task
        activePort = port
        activeHost = host
        activeRunID = runID
        running = true
        stateLock.unlock()

        Log.app.info("Bridge listening on \(host):\(port)")
    }

    private func markStopped(runID: UUID) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeRunID == runID else { return }
        serverTask = nil
        activePort = nil
        activeHost = nil
        activeRunID = nil
        running = false
    }

    private func makeApplication(host: String, port: Int) -> Application<RouterResponder<BasicRequestContext>> {
        let service = self.service
        let router = Router()

        router.get("v1/health") { request, _ async -> Response in
            guard Self.isAuthorized(request) else { return Self.emptyResponse(status: 404, reason: "Not Found") }
            let payload = await service.health()
            return Self.jsonResponse(payload)
        }

        router.get("v1/pairing") { request, _ async -> Response in
            guard Self.isAuthorized(request) else { return Self.emptyResponse(status: 404, reason: "Not Found") }
            let payload = BridgePairingPayload.current()
            return Self.jsonResponse(payload)
        }

        router.get("v1/settings") { request, _ async -> Response in
            guard Self.isAuthorized(request) else { return Self.emptyResponse(status: 404, reason: "Not Found") }
            let payload = await service.settings()
            return Self.jsonResponse(payload)
        }

        router.post("v1/settings") { request, _ async -> Response in
            guard Self.isAuthorized(request) else { return Self.emptyResponse(status: 404, reason: "Not Found") }
            do {
                let payload = try await Self.decodeJSON(BridgeSettingsUpdateRequest.self, from: request)
                let response = try await service.updateSettings(payload)
                return Self.jsonResponse(response)
            } catch {
                return Self.errorResponse(error)
            }
        }

        router.post("v1/dictate") { request, _ async -> Response in
            guard Self.isAuthorized(request) else { return Self.emptyResponse(status: 404, reason: "Not Found") }
            do {
                let payload = try await Self.decodeDictateRequest(from: request)
                let response = try await service.dictate(payload)
                return Self.jsonResponse(response)
            } catch {
                return Self.errorResponse(error)
            }
        }

        router.post("v1/restyle") { request, _ async -> Response in
            guard Self.isAuthorized(request) else { return Self.emptyResponse(status: 404, reason: "Not Found") }
            do {
                let payload = try await Self.decodeJSON(BridgeRestyleRequest.self, from: request)
                let response = try await service.restyle(payload)
                return Self.jsonResponse(response)
            } catch {
                return Self.errorResponse(error)
            }
        }

        router.post("v1/edit-text") { request, _ async -> Response in
            guard Self.isAuthorized(request) else { return Self.emptyResponse(status: 404, reason: "Not Found") }
            do {
                let payload = try await Self.decodeJSON(BridgeTextEditRequest.self, from: request)
                let response = try await service.editText(payload)
                return Self.jsonResponse(response)
            } catch {
                return Self.errorResponse(error)
            }
        }

        return Application(
            router: router,
            configuration: .init(
                address: .hostname(host, port: port),
                serverName: nil,
                reuseAddress: true
            )
        )
    }

    private static func isAuthorized(_ request: Request) -> Bool {
        let token = AppSettings.bridgeAuthToken
        let auth = request.headers[.authorization] ?? ""
        guard auth.hasPrefix("Bearer ") else { return false }
        return constantTimeEquals(String(auth.dropFirst(7)), token)
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from request: Request) async throws -> T {
        guard request.headers[.contentType]?.lowercased().contains("application/json") == true else {
            throw BridgeServiceError.invalidRequest("Content-Type must be application/json")
        }
        let body = try await request.body.collect(upTo: Self.maxBodyBytes)
        return try JSONDecoder().decode(T.self, from: Data(body.readableBytesView))
    }

    private static func jsonResponse<T: Encodable>(_ value: T, status: Int = 200, reason: String = "OK") -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return errorResponse(500, "Internal Server Error", "Could not encode response")
        }
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        return Response(
            status: HTTPResponse.Status(code: status, reasonPhrase: reason),
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }

    private static func errorResponse(_ error: Error) -> Response {
        if let bridgeError = error as? BridgeServiceError {
            return errorResponse(400, "Bad Request", bridgeError.localizedDescription)
        }
        if let multipartError = error as? BridgeMultipartError {
            return errorResponse(400, "Bad Request", multipartError.localizedDescription)
        }
        if error is DecodingError {
            return errorResponse(400, "Bad Request", "Invalid JSON request")
        }
        return errorResponse(500, "Internal Server Error", error.localizedDescription)
    }

    private static func errorResponse(_ status: Int, _ reason: String, _ message: String) -> Response {
        jsonResponse(BridgeErrorResponse(error: message), status: status, reason: reason)
    }

    private static func emptyResponse(status: Int, reason: String) -> Response {
        Response(status: HTTPResponse.Status(code: status, reasonPhrase: reason))
    }

    private static func decodeDictateRequest(from request: Request) async throws -> BridgeDictateRequest {
        let contentType = request.headers[.contentType] ?? ""
        let buffer = try await request.body.collect(upTo: Self.maxBodyBytes)
        let parts = try BridgeMultipart.parseFormData(
            Data(buffer.readableBytesView),
            contentType: contentType,
            maxHeaderBytes: Self.maxMultipartHeaderBytes
        )
        var fields: [String: String] = [:]
        var audioData: Data?
        var audioFilename: String?

        for part in parts {
            if part.name == "audio" {
                guard part.data.count <= Self.maxBodyBytes else {
                    throw BridgeServiceError.invalidRequest("Audio part is too large")
                }
                audioData = part.data
                audioFilename = part.filename
            } else if let value = String(data: part.data, encoding: .utf8) {
                guard part.data.count <= Self.maxMultipartFieldBytes else {
                    throw BridgeServiceError.invalidRequest("Multipart field is too large: \(part.name)")
                }
                fields[part.name] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let audioData, !audioData.isEmpty else {
            throw BridgeServiceError.invalidAudio
        }

        return BridgeDictateRequest(
            audioData: audioData,
            audioExtension: fields["audio_extension"] ?? audioFilename.flatMap(fileExtension),
            languageIDs: parseLanguageIDs(fields["language_ids"]),
            languageMode: fields["language_mode"],
            correctionMode: fields["correction_mode"],
            appName: fields["app_name"],
            bundleID: fields["bundle_id"],
            appCategory: fields["app_category"],
            contextBefore: fields["context_before"],
            contextAfter: fields["context_after"],
            includeRawTranscript: parseBool(fields["include_raw_transcript"])
        )
    }

    private static func parseLanguageIDs(_ raw: String?) -> [String]? {
        guard let raw, !raw.isEmpty else { return nil }
        if let data = raw.data(using: .utf8),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            return ids
        }
        return raw
            .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func parseBool(_ raw: String?) -> Bool? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        return ["1", "true", "yes", "y"].contains(raw)
    }

    private static func fileExtension(_ filename: String) -> String? {
        let ext = URL(fileURLWithPath: filename).pathExtension
        return ext.isEmpty ? nil : ext
    }
}

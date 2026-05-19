import Foundation

enum BridgeServiceError: LocalizedError {
    case invalidAudio
    case emptyTranscript
    case missingSession
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .invalidAudio:
            return "Invalid or empty audio payload"
        case .emptyTranscript:
            return "Audio produced an empty transcript"
        case .missingSession:
            return "Restyle session not found or expired"
        case .invalidRequest(let why):
            return "Invalid request: \(why)"
        }
    }
}

private struct BridgeSession {
    let id: String
    let rawTranscript: String
    let languageIDs: [String]
    let correctionMode: CorrectionMode
    let appName: String?
    let bundleID: String?
    let appCategory: AppCategory
    let contextBefore: String
    let contextAfter: String
    let createdAt: Date
}

private struct BridgeCorrectionOutput {
    let result: CorrectionResult
    let status: String
    let error: String?
}

@MainActor
final class BridgeService {
    private let dictionary: UserDictionaryStore
    private let textEditService: TextEditService
    private var sessions: [String: BridgeSession] = [:]

    private static let sessionTTL: TimeInterval = 15 * 60

    init(dictionary: UserDictionaryStore) {
        self.dictionary = dictionary
        self.textEditService = TextEditService(dictionary: dictionary)
    }

    func health() -> BridgeHealthResponse {
        BridgeHealthResponse(
            ok: true,
            service: "Typeforme Bridge",
            version: appVersion(),
            bridgePort: AppSettings.bridgePort
        )
    }

    func settings() -> BridgeSettingsPayload {
        BridgeSettingsPayload.current()
    }

    func updateSettings(_ request: BridgeSettingsUpdateRequest) async throws -> BridgeSettingsPayload {
        let oldASRProvider = BridgeSettingsPayload.normalizedASRProvider(AppSettings.asrProvider)
        let provider = try resolveASRProvider(request.asrProvider) ?? oldASRProvider
        let supportedLanguages = ASRLanguageSelection.supportedOptions(forProvider: provider)
        let languageIDs = ASRLanguageSelection.validatedIDs(
            request.languageIDs ?? AppSettings.asrLanguageIDs,
            supportedOptions: supportedLanguages
        )

        if request.asrProvider != nil {
            UserDefaults.standard.set(provider, forKey: AppSettings.Keys.asrProvider)
        }
        if request.languageIDs != nil || request.asrProvider != nil {
            UserDefaults.standard.set(
                ASRLanguageSelection.rawValue(for: languageIDs, supportedOptions: supportedLanguages),
                forKey: AppSettings.Keys.asrLanguageIDs
            )
        }
        if let timeoutSec = request.asrTimeoutSec {
            let clamped = min(max(timeoutSec, 10), 300)
            let key = provider == "whisperkit"
                ? AppSettings.Keys.asrWhisperKitTimeoutSec
                : AppSettings.Keys.asrQwenLlamaTimeoutSec
            UserDefaults.standard.set(Double(clamped), forKey: key)
        }

        if let rawBackend = request.correctionBackend {
            let backend = try resolveCorrectionBackend(rawBackend)
            UserDefaults.standard.set(backend.rawValue, forKey: AppSettings.Keys.correctionBackend)
        }
        if let timeoutMs = request.correctionTimeoutMs {
            UserDefaults.standard.set(min(max(timeoutMs, 100), 30_000), forKey: AppSettings.Keys.correctionTimeoutMs)
        }
        if let timeoutMs = request.correctionColdTimeoutMs {
            UserDefaults.standard.set(min(max(timeoutMs, 1_000), 60_000), forKey: AppSettings.Keys.correctionColdTimeoutMs)
        }
        if let rawURL = request.lmStudioBaseURL {
            UserDefaults.standard.set(try normalizedLMStudioBaseURL(rawURL), forKey: AppSettings.Keys.lmStudioBaseURL)
        }
        if let rawModel = request.lmStudioModel {
            UserDefaults.standard.set(rawModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: AppSettings.Keys.lmStudioModel)
        }

        if let rawMode = request.correctionMode {
            guard let mode = CorrectionMode(rawValue: rawMode) else {
                throw BridgeServiceError.invalidRequest("Unknown correction mode: \(rawMode)")
            }
            UserDefaults.standard.set(mode.rawValue, forKey: AppSettings.Keys.correctionMode)
        }
        if let rawPreference = request.numberOutputPreference {
            guard let preference = NumberOutputPreference(rawValue: rawPreference) else {
                throw BridgeServiceError.invalidRequest("Unknown number output preference: \(rawPreference)")
            }
            UserDefaults.standard.set(preference.rawValue, forKey: AppSettings.Keys.numberOutputPreference)
        }
        if let rawPreference = request.punctuationPreference {
            guard let preference = PunctuationOutputPreference(rawValue: rawPreference) else {
                throw BridgeServiceError.invalidRequest("Unknown punctuation preference: \(rawPreference)")
            }
            UserDefaults.standard.set(preference.rawValue, forKey: AppSettings.Keys.punctuationPreference)
        }

        if let autoCommit = request.autoCommit {
            UserDefaults.standard.set(autoCommit, forKey: AppSettings.Keys.correctionAutoCommit)
        }
        if let debugMode = request.debugMode {
            UserDefaults.standard.set(debugMode, forKey: AppSettings.Keys.diagnosticsDebugMode)
        }

        UserDefaults.standard.synchronize()
        let newASRProvider = BridgeSettingsPayload.normalizedASRProvider(AppSettings.asrProvider)
        Task { @MainActor in
            if oldASRProvider != newASRProvider, oldASRProvider == "qwen3-asr-llama" {
                await ASRFactory.shared.stopQwenLlama()
            }
            async let asrPreload: Void = ASRFactory.shared.preloadCachedActiveModel()
            async let correctionPreload: CorrectorPreloadResult = CorrectorFactory.shared.preloadActiveModels()
            _ = await (asrPreload, correctionPreload)
        }
        return BridgeSettingsPayload.current()
    }

    func dictate(_ request: BridgeDictateRequest) async throws -> BridgeDictateResponse {
        pruneExpiredSessions()
        let start = Date()
        let languageIDs = resolveLanguageIDs(ids: request.languageIDs, mode: request.languageMode)
        let correctionMode = try resolveCorrectionMode(request.correctionMode)
        let audioURL = try writeAudio(request)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let appCategory = resolveAppCategory(rawValue: request.appCategory, bundleID: request.bundleID)
        let debugLog = DebugLogStore.begin(
            source: "bridge",
            audioURL: audioURL,
            selectedCorrectionMode: correctionMode,
            languageIDs: languageIDs,
            appName: request.appName,
            bundleID: request.bundleID,
            appCategory: appCategory
        )

        let asrStarted = Date()
        let raw: String
        let transcriptionLatencyMs: Int
        do {
            raw = try await ASRFactory.shared.get().transcribe(audioFileURL: audioURL, languageIDs: languageIDs)
            transcriptionLatencyMs = elapsedMs(since: asrStarted)
            DebugLogStore.recordASR(
                debugLog,
                text: raw,
                status: "ok",
                latencyMs: transcriptionLatencyMs
            )
        } catch {
            DebugLogStore.recordASR(
                debugLog,
                text: nil,
                status: "error",
                error: error.localizedDescription,
                latencyMs: elapsedMs(since: asrStarted)
            )
            throw error
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BridgeServiceError.emptyTranscript }
        let contextBefore = request.contextBefore ?? ""
        let contextAfter = request.contextAfter ?? ""
        let debugRequest = correctionRequest(
            rawTranscript: trimmed,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: request.appName,
            bundleID: request.bundleID,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter
        )

        let correctionStarted = Date()
        let correction: BridgeCorrectionOutput
        let correctionLatencyMs: Int
        do {
            correction = try await correct(
                rawTranscript: trimmed,
                languageIDs: languageIDs,
                correctionMode: correctionMode,
                appName: request.appName,
                bundleID: request.bundleID,
                appCategory: appCategory,
                contextBefore: contextBefore,
                contextAfter: contextAfter
            )
            correctionLatencyMs = elapsedMs(since: correctionStarted)
        } catch {
            let latencyMs = elapsedMs(since: correctionStarted)
            guard Self.isCorrectionTimeout(error) else {
                DebugLogStore.recordCorrection(
                    debugLog,
                    mode: correctionMode,
                    text: nil,
                    status: "error",
                    error: error.localizedDescription,
                    latencyMs: latencyMs,
                    request: debugRequest,
                    timeoutMs: AppSettings.correctionTimeoutMs
                )
                throw error
            }
            let timeoutResult = normalize(
                CorrectionResult(action: .commit, text: trimmed, risk: .medium),
                languageIDs: languageIDs,
                correctionMode: correctionMode
            )
            correction = BridgeCorrectionOutput(
                result: timeoutResult,
                status: "timeout",
                error: error.localizedDescription
            )
            correctionLatencyMs = latencyMs
        }
        DebugLogStore.recordCorrection(
            debugLog,
            mode: correctionMode,
            text: correction.result.text,
            status: correction.status,
            error: correction.error,
            latencyMs: correctionLatencyMs,
            request: debugRequest,
            timeoutMs: AppSettings.correctionTimeoutMs
        )

        let sessionID = UUID().uuidString
        sessions[sessionID] = BridgeSession(
            id: sessionID,
            rawTranscript: trimmed,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: request.appName,
            bundleID: request.bundleID,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            createdAt: Date()
        )

        return BridgeDictateResponse(
            sessionID: sessionID,
            text: correction.result.text,
            correctionMode: correctionMode.rawValue,
            languageIDs: languageIDs,
            latencyMs: elapsedMs(since: start),
            transcriptionLatencyMs: transcriptionLatencyMs,
            correctionLatencyMs: correctionLatencyMs,
            rawTranscript: request.includeRawTranscript == true ? trimmed : nil,
            correctionStatus: correction.status,
            correctionError: correction.error
        )
    }

    func restyle(_ request: BridgeRestyleRequest) async throws -> BridgeRestyleResponse {
        pruneExpiredSessions()
        let start = Date()
        let session = request.sessionID.flatMap { sessions[$0] }
        let correctionMode = try resolveCorrectionMode(request.correctionMode ?? session?.correctionMode.rawValue)
        let providedRawTranscript = request.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTranscript = session?.rawTranscript ?? providedRawTranscript
        guard let rawTranscript, !rawTranscript.isEmpty else {
            throw BridgeServiceError.missingSession
        }

        let languageIDs = resolveLanguageIDs(
            ids: request.languageIDs ?? session?.languageIDs,
            mode: request.languageMode
        )
        let bundleID = request.bundleID ?? session?.bundleID
        let appName = request.appName ?? session?.appName
        let contextBefore = request.contextBefore ?? session?.contextBefore ?? ""
        let contextAfter = request.contextAfter ?? session?.contextAfter ?? ""
        let appCategory = resolveAppCategory(
            rawValue: request.appCategory,
            bundleID: bundleID,
            defaultCategory: session?.appCategory ?? .unknown
        )

        let correctionStarted = Date()
        let correction: BridgeCorrectionOutput
        let correctionLatencyMs: Int
        do {
            correction = try await correct(
                rawTranscript: rawTranscript,
                languageIDs: languageIDs,
                correctionMode: correctionMode,
                appName: appName,
                bundleID: bundleID,
                appCategory: appCategory,
                contextBefore: contextBefore,
                contextAfter: contextAfter
            )
            correctionLatencyMs = elapsedMs(since: correctionStarted)
        } catch {
            let latencyMs = elapsedMs(since: correctionStarted)
            guard Self.isCorrectionTimeout(error) else { throw error }
            let timeoutResult = normalize(
                CorrectionResult(action: .commit, text: rawTranscript, risk: .medium),
                languageIDs: languageIDs,
                correctionMode: correctionMode
            )
            correction = BridgeCorrectionOutput(
                result: timeoutResult,
                status: "timeout",
                error: error.localizedDescription
            )
            correctionLatencyMs = latencyMs
        }
        let sessionID = session?.id ?? UUID().uuidString
        sessions[sessionID] = BridgeSession(
            id: sessionID,
            rawTranscript: rawTranscript,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            createdAt: Date()
        )

        return BridgeRestyleResponse(
            sessionID: sessionID,
            text: correction.result.text,
            correctionMode: correctionMode.rawValue,
            languageIDs: languageIDs,
            latencyMs: elapsedMs(since: start),
            correctionLatencyMs: correctionLatencyMs,
            correctionStatus: correction.status,
            correctionError: correction.error
        )
    }

    private static func isCorrectionTimeout(_ error: Error) -> Bool {
        if let correctorError = error as? CorrectorError, correctorError == .timeout {
            return true
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("timed out")
    }

    func editText(_ request: BridgeTextEditRequest) async throws -> BridgeTextEditResponse {
        let start = Date()
        let intent = try resolveTextEditIntent(request.intent)
        let contextBefore = request.contextBefore ?? ""
        let targetText = request.targetText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let contextAfter = request.contextAfter ?? ""
        let spokenInstruction = request.spokenInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !targetText.isEmpty else {
            throw BridgeServiceError.invalidRequest("target_text is required")
        }
        guard !spokenInstruction.isEmpty else {
            throw BridgeServiceError.invalidRequest("spoken_instruction is required")
        }

        let languageIDs = resolveLanguageIDs(ids: request.languageIDs, mode: request.languageMode)
        let appCategory = resolveAppCategory(rawValue: request.appCategory, bundleID: request.bundleID)
        let editStarted = Date()
        let result = try await textEditService.edit(
            intent: intent,
            contextBefore: contextBefore,
            targetText: targetText,
            contextAfter: contextAfter,
            spokenInstruction: spokenInstruction,
            languageIDs: languageIDs,
            appName: request.appName,
            bundleID: request.bundleID,
            appCategory: appCategory
        )
        let editLatencyMs = elapsedMs(since: editStarted)
        return BridgeTextEditResponse(
            text: result.text,
            action: result.action.rawValue,
            languageIDs: languageIDs,
            latencyMs: elapsedMs(since: start),
            editLatencyMs: editLatencyMs,
            editStatus: "ok",
            editError: nil
        )
    }

    private func correct(
        rawTranscript: String,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        appName: String?,
        bundleID: String?,
        appCategory: AppCategory,
        contextBefore: String = "",
        contextAfter: String = ""
    ) async throws -> BridgeCorrectionOutput {
        let request = correctionRequest(
            rawTranscript: rawTranscript,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter
        )

        var result = try await CorrectorFactory.shared.make().correct(
            request,
            timeoutMs: AppSettings.correctionTimeoutMs
        )
        result = normalize(result, languageIDs: languageIDs, correctionMode: correctionMode)
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CorrectorError.empty
        }
        return BridgeCorrectionOutput(result: result, status: "ok", error: nil)
    }

    private func correctionRequest(
        rawTranscript: String,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        appName: String?,
        bundleID: String?,
        appCategory: AppCategory,
        contextBefore: String = "",
        contextAfter: String = ""
    ) -> CorrectionRequest {
        CorrectionRequest(
            correctionMode: correctionMode,
            frontmostAppName: appName,
            frontmostBundleID: bundleID,
            appCategory: appCategory,
            languageIDs: languageIDs,
            rawTranscript: rawTranscript,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            numberOutputPreference: AppSettings.numberOutputPreference,
            punctuationPreference: AppSettings.punctuationPreference,
            userDictionary: dictionary.sortedSnapshot()
        )
    }

    private func normalize(
        _ result: CorrectionResult,
        languageIDs: [String],
        correctionMode: CorrectionMode
    ) -> CorrectionResult {
        var normalized = result
        normalized.text = LocaleTextNormalizer.normalize(result.text, languageIDs: languageIDs)
        normalized.text = TranscriptPostProcessor.clean(
            normalized.text,
            languageIDs: languageIDs,
            preserveLineBreaks: correctionMode == .structurePlus,
            numberPreference: AppSettings.numberOutputPreference,
            punctuationPreference: AppSettings.punctuationPreference
        )
        return normalized
    }

    private func writeAudio(_ request: BridgeDictateRequest) throws -> URL {
        guard let data = request.audioData, !data.isEmpty else {
            throw BridgeServiceError.invalidAudio
        }
        try AppPaths.ensureDirectories()
        let ext = try validatedClientAudioExtension(request.audioExtension)
        let url = AppPaths.bridgeDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func validatedClientAudioExtension(_ extensionHint: String?) throws -> String {
        let defaultExtension = "m4a"
        guard let extensionHint else { return defaultExtension }
        let allowed = extensionHint
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        guard !allowed.isEmpty, allowed.count <= 8 else { return defaultExtension }
        guard ["m4a", "aac"].contains(allowed) else {
            throw BridgeServiceError.invalidRequest("Unsupported audio extension: \(allowed)")
        }
        return allowed
    }

    private func resolveCorrectionMode(_ rawMode: String?) throws -> CorrectionMode {
        if let rawMode, !rawMode.isEmpty {
            guard let mode = CorrectionMode(rawValue: rawMode) else {
                throw BridgeServiceError.invalidRequest("Unknown correction mode: \(rawMode)")
            }
            return mode
        }
        return AppSettings.correctionMode
    }

    private func resolveTextEditIntent(_ rawIntent: String?) throws -> TextEditIntent {
        guard let rawIntent, !rawIntent.isEmpty else { return .repairSelection }
        guard let intent = TextEditIntent(rawValue: rawIntent) else {
            throw BridgeServiceError.invalidRequest("Unknown text edit intent: \(rawIntent)")
        }
        return intent
    }

    private func resolveLanguageIDs(ids: [String]?, mode: String?) -> [String] {
        let supportedOptions = ASRLanguageSelection.supportedOptions(forProvider: AppSettings.asrProvider)
        if let ids, !ids.isEmpty {
            return ASRLanguageSelection.validatedIDs(ids, supportedOptions: supportedOptions)
        }
        switch mode?.lowercased() {
        case "zh", "zh-cn", "chinese", "chinese_simplified":
            return ASRLanguageSelection.validatedIDs(["zh-CN"], supportedOptions: supportedOptions)
        case "en", "en-us", "english":
            return ASRLanguageSelection.validatedIDs(["en-US"], supportedOptions: supportedOptions)
        case "mixed", "multi", "multilingual", "zh-en":
            return ASRLanguageSelection.validatedIDs(["zh-CN", "en-US"], supportedOptions: supportedOptions)
        default:
            return ASRLanguageSelection.validatedIDs(AppSettings.asrLanguageIDs, supportedOptions: supportedOptions)
        }
    }

    private func resolveASRProvider(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        guard BridgeSettingsPayload.controllableASRProviders.contains(where: { $0.id == value }) else {
            throw BridgeServiceError.invalidRequest("Unknown ASR provider: \(raw)")
        }
        return value
    }

    private func resolveCorrectionBackend(_ raw: String) throws -> CorrectionBackendKind {
        guard let backend = CorrectionBackendKind(rawValue: raw),
              BridgeSettingsPayload.controllableCorrectionBackends.contains(backend)
        else {
            throw BridgeServiceError.invalidRequest("Unknown correction backend: \(raw)")
        }
        return backend
    }

    private func normalizedLMStudioBaseURL(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return value
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else {
            throw BridgeServiceError.invalidRequest("Invalid LM Studio base URL: \(raw)")
        }
        return value
    }

    private func resolveAppCategory(
        rawValue: String?,
        bundleID: String?,
        defaultCategory: AppCategory = .unknown
    ) -> AppCategory {
        if let rawValue, let category = AppCategory(rawValue: rawValue) {
            return category
        }
        let inferred = AppCategory.from(bundleID: bundleID)
        return inferred == .unknown ? defaultCategory : inferred
    }

    private func pruneExpiredSessions() {
        let cutoff = Date().addingTimeInterval(-Self.sessionTTL)
        sessions = sessions.filter { $0.value.createdAt >= cutoff }
    }

    private func elapsedMs(since date: Date) -> Int {
        Int((Date().timeIntervalSince(date) * 1000).rounded())
    }

    private func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }

}

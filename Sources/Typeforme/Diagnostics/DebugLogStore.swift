import Foundation

struct DebugLogHandle {
    let id: String
    let directory: URL
}

private struct DebugLogTranscript: Codable {
    var status: String
    var text: String?
    var error: String?
    var latencyMs: Int?
    var provider: String?
    var model: String?
    var maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case text
        case error
        case latencyMs = "latency_ms"
        case provider
        case model
        case maxTokens = "max_tokens"
    }
}

private struct DebugLogCorrection: Codable {
    var correctionMode: String
    var backend: String
    var model: String
    var maxTokens: Int
    var timeoutMs: Int?
    var status: String
    var text: String?
    var error: String?
    var latencyMs: Int?
    var input: DebugLogCorrectionInput?

    enum CodingKeys: String, CodingKey {
        case correctionMode = "correction_mode"
        case backend
        case model
        case maxTokens = "max_tokens"
        case timeoutMs = "timeout_ms"
        case status
        case text
        case error
        case latencyMs = "latency_ms"
        case input
    }
}

private struct DebugLogCorrectionInput: Codable {
    var rawTranscript: String
    var contextBefore: String
    var contextAfter: String
    var frontmostAppName: String?
    var frontmostBundleID: String?
    var appCategory: String
    var languageIDs: [String]
    var numberOutputPreference: String
    var punctuationPreference: String
    var userDictionaryCount: Int
    var rawTranscriptChars: Int
    var contextBeforeChars: Int
    var contextAfterChars: Int

    enum CodingKeys: String, CodingKey {
        case rawTranscript = "raw_transcript"
        case contextBefore = "context_before"
        case contextAfter = "context_after"
        case frontmostAppName = "frontmost_app_name"
        case frontmostBundleID = "frontmost_bundle_id"
        case appCategory = "app_category"
        case languageIDs = "language_ids"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case userDictionaryCount = "user_dictionary_count"
        case rawTranscriptChars = "raw_transcript_chars"
        case contextBeforeChars = "context_before_chars"
        case contextAfterChars = "context_after_chars"
    }
}

private struct DebugLogRecord: Codable {
    var id: String
    var createdAt: String
    var source: String
    var audioFile: String?
    var audioCopyError: String?
    var asrProvider: String
    var asrModel: String
    var asrMaxTokens: Int?
    var correctionBackend: String
    var correctionModel: String
    var correctionMaxTokens: Int
    var selectedCorrectionMode: String
    var languageIDs: [String]
    var transcript: DebugLogTranscript?
    var correction: DebugLogCorrection?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case source
        case audioFile = "audio_file"
        case audioCopyError = "audio_copy_error"
        case asrProvider = "asr_provider"
        case asrModel = "asr_model"
        case asrMaxTokens = "asr_max_tokens"
        case correctionBackend = "correction_backend"
        case correctionModel = "correction_model"
        case correctionMaxTokens = "correction_max_tokens"
        case selectedCorrectionMode = "selected_correction_mode"
        case languageIDs = "language_ids"
        case transcript
        case correction
    }
}

@MainActor
enum DebugLogStore {
    private static let recordFileName = "record.json"

    static var isEnabled: Bool {
        AppSettings.diagnosticsDebugMode
    }

    static func begin(
        source: String,
        audioURL: URL?,
        selectedCorrectionMode: CorrectionMode,
        languageIDs: [String],
        appName _: String?,
        bundleID _: String?,
        appCategory _: AppCategory
    ) -> DebugLogHandle? {
        guard isEnabled else { return nil }
        do {
            try AppPaths.ensureDirectories()
            let createdAt = ISO8601DateFormatter().string(from: Date())
            let id = safeID(createdAt)
            let directory = AppPaths.debugCapturesDir.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            var audioFileName: String?
            var audioCopyError: String?
            if let audioURL {
                do {
                    audioFileName = try saveReceivedAudio(audioURL, in: directory)
                } catch {
                    audioCopyError = error.localizedDescription
                }
            }

            let record = DebugLogRecord(
                id: id,
                createdAt: createdAt,
                source: source,
                audioFile: audioFileName,
                audioCopyError: audioCopyError,
                asrProvider: AppSettings.asrProvider,
                asrModel: activeASRModelDescription(),
                asrMaxTokens: activeASRMaxTokens(),
                correctionBackend: AppSettings.correctionBackend.rawValue,
                correctionModel: activeCorrectionModelDescription(),
                correctionMaxTokens: AppSettings.correctionMaxTokens,
                selectedCorrectionMode: selectedCorrectionMode.rawValue,
                languageIDs: languageIDs,
                transcript: nil,
                correction: nil
            )
            try write(record, in: directory)
            prune()
            Log.store.info("debug capture started: \(id, privacy: .public)")
            return DebugLogHandle(id: id, directory: directory)
        } catch {
            Log.store.error("debug capture start failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func recordASR(
        _ handle: DebugLogHandle?,
        text: String?,
        status: String,
        error: String? = nil,
        latencyMs: Int? = nil
    ) {
        mutate(handle) { record in
            record.transcript = DebugLogTranscript(
                status: status,
                text: text,
                error: error,
                latencyMs: latencyMs,
                provider: AppSettings.asrProvider,
                model: activeASRModelDescription(),
                maxTokens: activeASRMaxTokens()
            )
        }
    }

    static func recordCorrection(
        _ handle: DebugLogHandle?,
        mode: CorrectionMode,
        text: String?,
        status: String,
        error: String? = nil,
        latencyMs: Int? = nil,
        request: CorrectionRequest? = nil,
        timeoutMs: Int? = nil
    ) {
        mutate(handle) { record in
            record.correction = DebugLogCorrection(
                correctionMode: mode.rawValue,
                backend: AppSettings.correctionBackend.rawValue,
                model: activeCorrectionModelDescription(),
                maxTokens: AppSettings.correctionMaxTokens,
                timeoutMs: timeoutMs,
                status: status,
                text: text,
                error: error,
                latencyMs: latencyMs,
                input: request.map(correctionInput)
            )
        }
    }

    static func recentCount() -> Int {
        entries().count
    }

    static func clear() {
        do {
            if FileManager.default.fileExists(atPath: AppPaths.debugCapturesDir.path) {
                try FileManager.default.removeItem(at: AppPaths.debugCapturesDir)
            }
            try AppPaths.ensureDirectories()
        } catch {
            Log.store.error("debug capture clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func prune() {
        let items = entries()
        for url in items.dropFirst(AppSettings.diagnosticsDebugCaptureLimit) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func mutate(
        _ handle: DebugLogHandle?,
        _ body: (inout DebugLogRecord) -> Void
    ) {
        guard let handle else { return }
        do {
            var record = try read(in: handle.directory)
            body(&record)
            try write(record, in: handle.directory)
        } catch {
            Log.store.error("debug capture update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func read(in directory: URL) throws -> DebugLogRecord {
        let data = try Data(contentsOf: directory.appendingPathComponent(recordFileName))
        return try JSONDecoder().decode(DebugLogRecord.self, from: data)
    }

    private static func correctionInput(_ request: CorrectionRequest) -> DebugLogCorrectionInput {
        DebugLogCorrectionInput(
            rawTranscript: request.rawTranscript,
            contextBefore: request.contextBefore,
            contextAfter: request.contextAfter,
            frontmostAppName: request.frontmostAppName,
            frontmostBundleID: request.frontmostBundleID,
            appCategory: request.appCategory.rawValue,
            languageIDs: request.languageIDs,
            numberOutputPreference: request.numberOutputPreference.rawValue,
            punctuationPreference: request.punctuationPreference.rawValue,
            userDictionaryCount: request.userDictionary.count,
            rawTranscriptChars: request.rawTranscript.count,
            contextBeforeChars: request.contextBefore.count,
            contextAfterChars: request.contextAfter.count
        )
    }

    private static func saveReceivedAudio(_ source: URL, in directory: URL) throws -> String {
        let ext = source.pathExtension.isEmpty ? "audio" : source.pathExtension.lowercased()
        let filename = "audio.\(ext)"
        let destination = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return filename
    }

    private static func write(_ record: DebugLogRecord, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: directory.appendingPathComponent(recordFileName), options: .atomic)
    }

    private static func entries() -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.debugCapturesDir,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return leftDate > rightDate
            }
    }

    private static func safeID(_ value: String) -> String {
        value
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .appending("-\(UUID().uuidString.prefix(8))")
    }

    private static func activeASRModelDescription() -> String {
        switch AppSettings.asrProvider.lowercased() {
        case "qwen3-asr-llama":
            return AppSettings.asrQwenLlamaModelID
        default:
            return AppSettings.asrModel
        }
    }

    private static func activeASRMaxTokens() -> Int? {
        switch AppSettings.asrProvider.lowercased() {
        case "qwen3-asr-llama":
            return AppSettings.asrQwenLlamaMaxTokens
        default:
            return nil
        }
    }

    private static func activeCorrectionModelDescription() -> String {
        switch AppSettings.correctionBackend {
        case .qwen35_2B:
            return URL(fileURLWithPath: AppSettings.llama2BPath).lastPathComponent
        case .qwen35_4B:
            return URL(fileURLWithPath: AppSettings.llama4BPath).lastPathComponent
        case .qwen35_9B:
            return URL(fileURLWithPath: AppSettings.llama9BPath).lastPathComponent
        case .externalLMStudio:
            return AppSettings.lmStudioModel
        }
    }

}

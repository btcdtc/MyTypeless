import Foundation
import WhisperKit

struct WhisperKitPreparationProgress: Equatable, Sendable {
    let completedUnitCount: Int64
    let totalUnitCount: Int64
    let fractionCompleted: Double?
    let isByteProgress: Bool

    init(_ progress: Progress) {
        completedUnitCount = progress.completedUnitCount
        totalUnitCount = progress.totalUnitCount
        isByteProgress = progress.totalUnitCount >= 1_000_000
        if progress.totalUnitCount > 0 {
            fractionCompleted = progress.fractionCompleted
        } else {
            fractionCompleted = nil
        }
    }
}

enum WhisperKitPreparationStage: Sendable {
    case downloading
    case loading
    case warmingUp
    case ready
}

struct WhisperKitModelCacheInfo: Equatable, Sendable {
    let modelFolder: URL
    let usesDocumentDirectoryCache: Bool
}

/// Spec §10: dev model `tiny`; normal `large-v3-v20240930_626MB`; lazy load;
/// optional unload after 5 idle minutes.
@MainActor
final class WhisperKitASRService: ASRService {
    let modelName: String
    private var pipe: WhisperKit?
    private var unloadTask: Task<Void, Never>?

    init(modelName: String) {
        self.modelName = modelName
    }

    func prepareModel(
        progress: (@MainActor @Sendable (WhisperKitPreparationProgress) -> Void)? = nil,
        stage: (@MainActor @Sendable (WhisperKitPreparationStage) -> Void)? = nil
    ) async throws -> URL {
        unloadTask?.cancel()

        if let p = pipe {
            if p.modelState != .loaded {
                stage?(.loading)
                Log.asr.info("loading cached WhisperKit model: \(self.modelName, privacy: .public)")
                try await p.loadModels()
            }
            scheduleUnload()
            stage?(.ready)
            return p.modelFolder ?? AppPaths.whisperKitCacheDir
        }

        try AppPaths.ensureDirectories()
        if let cached = Self.cachedModelInfo(for: modelName) {
            stage?(.loading)
            Log.asr.info("loading cached WhisperKit model: \(self.modelName, privacy: .public)")
            let p = try await WhisperKit(
                modelFolder: cached.modelFolder.path,
                verbose: false,
                logLevel: .error,
                load: true,
                download: false
            )
            pipe = p
            scheduleUnload()
            stage?(.ready)
            return cached.modelFolder
        }

        stage?(.downloading)
        Log.asr.info("downloading WhisperKit model: \(self.modelName, privacy: .public)")
        let modelFolder = try await WhisperKit.download(
            variant: modelName,
            downloadBase: AppPaths.whisperKitCacheDir
        ) { update in
            guard let progress else { return }
            let snapshot = WhisperKitPreparationProgress(update)
            Task { @MainActor in
                progress(snapshot)
            }
        }

        stage?(.warmingUp)
        Log.asr.info("prewarming WhisperKit model: \(self.modelName, privacy: .public)")
        let p = try await WhisperKit(
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        pipe = p
        scheduleUnload()
        stage?(.ready)
        Log.asr.info("WhisperKit model ready: \(self.modelName, privacy: .public)")
        return modelFolder
    }

    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        let timeoutSeconds = AppSettings.asrWhisperKitTimeoutSeconds
        let operation = Task { @MainActor in
            try await self.transcribeWithoutTimeout(audioFileURL: audioFileURL, languageIDs: languageIDs)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completion = OneShotTranscriptionCompletion()
                Task {
                    do {
                        let text = try await operation.value
                        completion.complete(continuation, result: .success(text))
                    } catch {
                        completion.complete(continuation, result: .failure(error))
                    }
                }
                Task {
                    try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds(seconds: timeoutSeconds))
                    guard !Task.isCancelled else { return }
                    operation.cancel()
                    completion.complete(
                        continuation,
                        result: .failure(ASRAudioSupportError.timeout(seconds: timeoutSeconds))
                    )
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private func transcribeWithoutTimeout(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        let pipeline = try await ensurePipeline()
        let languageCodes = ASRLanguageSelection.whisperCodes(for: languageIDs)
        let languageHint = ASRLanguageSelection.whisperLanguageHint(for: languageIDs)

        var options = decodingOptions(language: languageHint, detectLanguage: languageHint == nil)
        var text = try await transcribeOnce(pipeline: pipeline, audioFileURL: audioFileURL, options: options)

        if text.isEmpty, languageHint == nil {
            Log.asr.notice("WhisperKit returned empty text with auto language detection; retrying selected language hints")
            for code in languageCodes {
                options = decodingOptions(language: code, detectLanguage: false)
                options.noSpeechThreshold = nil
                text = try await transcribeOnce(pipeline: pipeline, audioFileURL: audioFileURL, options: options)
                if !text.isEmpty {
                    Log.asr.info("WhisperKit retry succeeded with language hint: \(code, privacy: .public)")
                    break
                }
            }
        }

        scheduleUnload()
        return LocaleTextNormalizer.normalize(text, languageIDs: languageIDs)
    }

    private nonisolated static func timeoutNanoseconds(seconds: TimeInterval) -> UInt64 {
        UInt64(max(1, seconds) * 1_000_000_000)
    }

    private func decodingOptions(language: String?, detectLanguage: Bool) -> DecodingOptions {
        var options = DecodingOptions()
        options.language = language
        options.detectLanguage = detectLanguage
        options.skipSpecialTokens = true
        return options
    }

    private func transcribeOnce(
        pipeline: WhisperKit,
        audioFileURL: URL,
        options: DecodingOptions
    ) async throws -> String {
        let results = try await pipeline.transcribe(
            audioPath: audioFileURL.path,
            decodeOptions: options
        )
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensurePipeline() async throws -> WhisperKit {
        if let p = pipe { return p }
        try AppPaths.ensureDirectories()
        if let cached = Self.cachedModelInfo(for: modelName) {
            Log.asr.info("loading cached WhisperKit model: \(self.modelName, privacy: .public)")
            let p = try await WhisperKit(
                modelFolder: cached.modelFolder.path,
                verbose: false,
                logLevel: .error,
                load: true,
                download: false
            )
            pipe = p
            Log.asr.info("WhisperKit ready")
            return p
        }

        Log.asr.info("loading WhisperKit model: \(self.modelName, privacy: .public)")
        let p = try await WhisperKit(
            model: modelName,
            downloadBase: AppPaths.whisperKitCacheDir,
            verbose: false,
            logLevel: .error
        )
        pipe = p
        Log.asr.info("WhisperKit ready")
        return p
    }

    private func scheduleUnload() {
        let minutes = AppSettings.asrUnloadAfterMinutes
        guard minutes > 0 else { return }
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes * 60) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    private func unload() {
        guard pipe != nil else { return }
        Log.asr.info("unloading WhisperKit after idle timeout")
        pipe = nil
    }

    nonisolated static func cachedModelInfo(for modelName: String) -> WhisperKitModelCacheInfo? {
        let current = cachedModelFolder(for: modelName, under: AppPaths.whisperKitCacheDir)
        if let current {
            return WhisperKitModelCacheInfo(modelFolder: current.standardizedFileURL, usesDocumentDirectoryCache: false)
        }

        let documentCache = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("huggingface", isDirectory: true)
        if let documentCache, let folder = cachedModelFolder(for: modelName, under: documentCache) {
            return WhisperKitModelCacheInfo(modelFolder: folder.standardizedFileURL, usesDocumentDirectoryCache: true)
        }
        return nil
    }

    private nonisolated static func cachedModelFolder(for modelName: String, under base: URL) -> URL? {
        let folder = base
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(modelName)", isDirectory: true)
        return isUsableModelFolder(folder) ? folder : nil
    }

    private nonisolated static func isUsableModelFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        for name in ["AudioEncoder", "MelSpectrogram", "TextDecoder"] {
            let compiled = folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            let package = folder.appendingPathComponent("\(name).mlpackage", isDirectory: true)
            if !fm.fileExists(atPath: compiled.path) && !fm.fileExists(atPath: package.path) {
                return false
            }
        }
        return true
    }
}

private final class OneShotTranscriptionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false

    func complete(
        _ continuation: CheckedContinuation<String, Error>,
        result: Result<String, Error>
    ) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        lock.unlock()
        continuation.resume(with: result)
    }
}

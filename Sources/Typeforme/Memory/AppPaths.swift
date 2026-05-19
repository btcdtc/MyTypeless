import Foundation

/// Filesystem paths for runtime artifacts. Per spec §12, §19, §23:
///   ~/Library/Application Support/Typeforme/
///     ├── Models/          (qwen3.5-*.gguf)
///     │   └── WhisperKit/  (WhisperKit HuggingFace/Core ML cache)
///     │   └── Qwen3ASR/    (optional local ASR model/cache folder)
///     ├── prompts/         (system.md and mode-*.md)
///     ├── Bridge/          (temporary uploaded audio)
///     ├── ASRWork/         (temporary audio for external ASR)
///     ├── DebugCaptures/   (opt-in debug captures)
///     ├── user_vocabulary.json
///     └── llama.pid
enum AppPaths {
    static let appSupportDir: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Typeforme", isDirectory: true)
    }()

    static let modelsDir: URL          = appSupportDir.appendingPathComponent("Models",            isDirectory: true)
    static let whisperKitCacheDir: URL = modelsDir.appendingPathComponent("WhisperKit",            isDirectory: true)
    static let qwen3ASRModelsDir: URL  = modelsDir.appendingPathComponent("Qwen3ASR",              isDirectory: true)
    static let promptsDir: URL         = appSupportDir.appendingPathComponent("prompts",           isDirectory: true)
    static let bridgeDir: URL          = appSupportDir.appendingPathComponent("Bridge",            isDirectory: true)
    static let asrWorkDir: URL         = appSupportDir.appendingPathComponent("ASRWork",           isDirectory: true)
    static let logsDir: URL            = appSupportDir.appendingPathComponent("Logs",              isDirectory: true)
    static let debugCapturesDir: URL   = appSupportDir.appendingPathComponent("DebugCaptures",     isDirectory: true)
    static let userDictionaryFile: URL = appSupportDir.appendingPathComponent("user_vocabulary.json")
    static let llamaPidFile: URL       = appSupportDir.appendingPathComponent("llama.pid")
    static let asrLlamaPidFile: URL    = appSupportDir.appendingPathComponent("qwen3-asr-llama.pid")
    static let llama2BFile: URL        = modelsDir.appendingPathComponent("qwen3.5-2b-q4_k_m.gguf")
    static let llama4BFile: URL        = modelsDir.appendingPathComponent("qwen3.5-4b-q4_k_m.gguf")
    static let llama9BFile: URL        = modelsDir.appendingPathComponent("qwen3.5-9b-q4_k_m.gguf")
    static let qwen3ASRGGUFFile: URL   = qwen3ASRModelsDir.appendingPathComponent("Qwen3-ASR-0.6B-Q8_0.gguf")
    static let qwen3ASRMMProjFile: URL = qwen3ASRModelsDir.appendingPathComponent("mmproj-Qwen3-ASR-0.6B-Q8_0.gguf")
    static let qwen3ASR06BF16File: URL = qwen3ASRModelsDir.appendingPathComponent("Qwen3-ASR-0.6B-bf16.gguf")
    static let qwen3ASR06BF16MMProjFile: URL = qwen3ASRModelsDir.appendingPathComponent("mmproj-Qwen3-ASR-0.6B-bf16.gguf")
    static let qwen3ASR17Q8File: URL = qwen3ASRModelsDir.appendingPathComponent("Qwen3-ASR-1.7B-Q8_0.gguf")
    static let qwen3ASR17Q8MMProjFile: URL = qwen3ASRModelsDir.appendingPathComponent("mmproj-Qwen3-ASR-1.7B-Q8_0.gguf")
    static let qwen3ASR17BF16File: URL = qwen3ASRModelsDir.appendingPathComponent("Qwen3-ASR-1.7B-bf16.gguf")
    static let qwen3ASR17BF16MMProjFile: URL = qwen3ASRModelsDir.appendingPathComponent("mmproj-Qwen3-ASR-1.7B-bf16.gguf")

    /// llama-server-arm64 helper bundled inside the .app at Contents/Resources/llama/.
    static var bundledLlamaServer: URL? {
        Bundle.main.url(forResource: "llama-server-arm64", withExtension: nil, subdirectory: "llama")
    }

    static func ensureDirectories() throws {
        let fm = FileManager.default
        for url in [appSupportDir, modelsDir, whisperKitCacheDir, qwen3ASRModelsDir, promptsDir, bridgeDir, asrWorkDir, logsDir, debugCapturesDir] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

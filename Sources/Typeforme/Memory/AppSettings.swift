import Foundation

/// Single source of truth for persisted settings. Backed by UserDefaults so
/// SwiftUI `@AppStorage` and service-side reads stay in sync.
/// Per spec §22 tabs: General, Recording, ASR, Correction, Prompts, Vocabulary,
/// Bridge, Diagnostics.
enum AppSettings {
    private static let currentMacDefaultsDomain = "com.btcdtc.typeforme.mac"

    enum Keys {
        // Recording
        static let maxRecordingDuration = "recording.maxDuration"   // seconds
        static let alwaysShowHUD        = "recording.alwaysShowHUD"
        static let holdModifier         = "recording.holdModifier"  // HoldModifier raw

        // ASR
        static let asrProvider          = "asr.provider"            // "whisperkit" | "qwen3-asr-llama"
        static let asrModel             = "asr.model"
        static let asrLanguageIDs       = "asr.languages"           // comma-separated ASRLanguageOption ids
        static let asrUnloadAfterMin    = "asr.unloadAfterMin"      // 0 disables
        static let asrWhisperKitTimeoutSec = "asr.whisperkit.timeoutSec"
        static let asrQwenLlamaTimeoutSec = "asr.qwen3.llama.timeoutSec"
        static let asrQwenLlamaModelID  = "asr.qwen3.llama.modelID"
        static let asrQwenLlamaMaxTokens = "asr.qwen3.llama.maxTokens"
        static let asrQwenLlamaModelPath = "asr.qwen3.llama.modelPath"
        static let asrQwenLlamaMMProjPath = "asr.qwen3.llama.mmprojPath"
        static let asrQwenLlamaModelDownloadURL = "asr.qwen3.llama.modelDownloadURL"
        static let asrQwenLlamaMMProjDownloadURL = "asr.qwen3.llama.mmprojDownloadURL"
        static let asrQwen06Q8ModelPath = "asr.qwen3.06q8.modelPath"
        static let asrQwen06Q8MMProjPath = "asr.qwen3.06q8.mmprojPath"
        static let asrQwen06Q8ModelDownloadURL = "asr.qwen3.06q8.modelDownloadURL"
        static let asrQwen06Q8MMProjDownloadURL = "asr.qwen3.06q8.mmprojDownloadURL"
        static let asrQwen06BF16ModelPath = "asr.qwen3.06bf16.modelPath"
        static let asrQwen06BF16MMProjPath = "asr.qwen3.06bf16.mmprojPath"
        static let asrQwen06BF16ModelDownloadURL = "asr.qwen3.06bf16.modelDownloadURL"
        static let asrQwen06BF16MMProjDownloadURL = "asr.qwen3.06bf16.mmprojDownloadURL"
        static let asrQwen17Q8ModelPath = "asr.qwen3.17q8.modelPath"
        static let asrQwen17Q8MMProjPath = "asr.qwen3.17q8.mmprojPath"
        static let asrQwen17Q8ModelDownloadURL = "asr.qwen3.17q8.modelDownloadURL"
        static let asrQwen17Q8MMProjDownloadURL = "asr.qwen3.17q8.mmprojDownloadURL"
        static let asrQwen17BF16ModelPath = "asr.qwen3.17bf16.modelPath"
        static let asrQwen17BF16MMProjPath = "asr.qwen3.17bf16.mmprojPath"
        static let asrQwen17BF16ModelDownloadURL = "asr.qwen3.17bf16.modelDownloadURL"
        static let asrQwen17BF16MMProjDownloadURL = "asr.qwen3.17bf16.mmprojDownloadURL"

        // Correction
        static let correctionBackend       = "correction.backend"   // CorrectionBackendKind raw
        static let correctionTimeoutMs     = "correction.timeoutMs"
        static let correctionColdTimeoutMs = "correction.coldTimeoutMs"
        static let correctionMaxTokens     = "correction.maxTokens"
        static let correctionContextSize   = "correction.contextSize"
        static let correctionMode   = "correction.mode"
        static let correctionAutoCommit    = "correction.autoCommit"
        static let numberOutputPreference  = "correction.numberOutputPreference"
        static let punctuationPreference   = "correction.punctuationPreference"
        static let llama2BPath             = "correction.llama2BPath"
        static let llama4BPath             = "correction.llama4BPath"
        static let llama9BPath             = "correction.llama9BPath"
        static let llama2BDownloadURL      = "correction.llama2BDownloadURL"
        static let llama4BDownloadURL      = "correction.llama4BDownloadURL"
        static let llama9BDownloadURL      = "correction.llama9BDownloadURL"
        static let llamaUseFlashAttn       = "correction.useFlashAttn"
        static let lmStudioBaseURL         = "correction.lmStudioBaseURL"
        static let lmStudioAPIKey          = "correction.lmStudioAPIKey"
        static let lmStudioModel           = "correction.lmStudioModel"

        // Prompts
        static let promptOverrideFolder = "prompts.overrideFolder"
        static let promptAdditionalSystem = "prompts.additionalSystem"

        // Processing role
        static let processingMode      = "processing.mode"
        static let clientLocalBridgeURLs = "processing.client.localBridgeURLs"
        static let clientCloudBridgeURL = "processing.client.cloudBridgeURL"
        static let clientBridgeToken   = "processing.client.bridgeToken"
        static let clientLanguageIDs   = "processing.client.languages"
        static let serverSettingsSnapshot = "processing.server.settingsSnapshot"
        static let clientSettingsSnapshot = "processing.client.settingsSnapshot"

        // Bridge
        static let bridgeEnabled    = "bridge.enabled"
        static let bridgeLANEnabled = "bridge.lanEnabled"
        static let bridgeLANAdapter = "bridge.lanAdapter"
        static let bridgePublicEnabled = "bridge.publicEnabled"
        static let bridgePort       = "bridge.port"
        static let bridgeAuthToken  = "bridge.authToken"
        static let bridgeHostname   = "bridge.hostname"

        // Diagnostics
        static let diagnosticsDebugMode = "diagnostics.debugMode"
        static let diagnosticsDebugCaptureLimit = "diagnostics.debugCaptureLimit"
    }

    static func registerDefaults() {
        let defaults: [String: Any] = [
            Keys.maxRecordingDuration: 30.0,
            Keys.alwaysShowHUD:        false,
            Keys.holdModifier:         HoldModifier.rightOption.rawValue,

            Keys.asrProvider:       "qwen3-asr-llama",
            Keys.asrModel:          "large-v3-v20240930_626MB",
            Keys.asrLanguageIDs:    ASRLanguageSelection.defaultRawValue,
            Keys.asrUnloadAfterMin: 0,
            Keys.asrWhisperKitTimeoutSec: 120,
            Keys.asrQwenLlamaTimeoutSec: 120,
            Keys.asrQwenLlamaModelID: QwenASRModelCatalog.defaultID,
            Keys.asrQwenLlamaMaxTokens: 2048,
            Keys.asrQwenLlamaModelPath: AppPaths.qwen3ASRGGUFFile.path,
            Keys.asrQwenLlamaMMProjPath: AppPaths.qwen3ASRMMProjFile.path,
            Keys.asrQwenLlamaModelDownloadURL: "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/main/Qwen3-ASR-0.6B-Q8_0.gguf?download=true",
            Keys.asrQwenLlamaMMProjDownloadURL: "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/main/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf?download=true",

            Keys.correctionBackend:       CorrectionBackendKind.qwen35_2B.rawValue,
            Keys.correctionTimeoutMs:     1500,
            Keys.correctionColdTimeoutMs: 8000,
            Keys.correctionMaxTokens:     128,
            Keys.correctionContextSize:   4096,
            Keys.correctionMode:   CorrectionMode.polish.rawValue,
            Keys.correctionAutoCommit:    true,
            Keys.numberOutputPreference:  NumberOutputPreference.automatic.rawValue,
            Keys.punctuationPreference:   PunctuationOutputPreference.normal.rawValue,
            Keys.llama2BPath:             AppPaths.llama2BFile.path,
            Keys.llama4BPath:             AppPaths.llama4BFile.path,
            Keys.llama9BPath:             AppPaths.llama9BFile.path,
            // Defaults point to unsloth's GGUF re-pack (most-downloaded community
            // quants for Qwen3.5). Editable in the Settings UI if you prefer
            // bartowski/lmstudio-community or a different quant level.
            Keys.llama2BDownloadURL:      "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf?download=true",
            Keys.llama4BDownloadURL:      "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf?download=true",
            Keys.llama9BDownloadURL:      "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf?download=true",
            Keys.llamaUseFlashAttn:       true,
            Keys.lmStudioBaseURL:         "http://127.0.0.1:1234/v1",
            Keys.lmStudioAPIKey:          "",
            Keys.lmStudioModel:           "",

            Keys.promptOverrideFolder: AppPaths.promptsDir.path,
            Keys.promptAdditionalSystem: "",

            Keys.processingMode:    ProcessingMode.client.rawValue,
            Keys.clientLocalBridgeURLs: "",
            Keys.clientCloudBridgeURL: "",
            Keys.clientBridgeToken: "",
            Keys.clientLanguageIDs: ASRLanguageSelection.defaultRawValue,

            Keys.bridgeEnabled:    false,
            Keys.bridgeLANEnabled: false,
            Keys.bridgeLANAdapter: "all",
            Keys.bridgePublicEnabled: false,
            Keys.bridgePort:       18081,
            Keys.bridgeHostname:   "",

            Keys.diagnosticsDebugMode: false,
            Keys.diagnosticsDebugCaptureLimit: 10,
        ]
        var registeredDefaults = defaults
        for spec in QwenASRModelCatalog.all {
            registeredDefaults[spec.modelPathKey] = spec.defaultModelPath
            registeredDefaults[spec.mmprojPathKey] = spec.defaultMMProjPath
            registeredDefaults[spec.modelURLKey] = spec.defaultModelURL
            registeredDefaults[spec.mmprojURLKey] = spec.defaultMMProjURL
        }
        UserDefaults.standard.register(defaults: registeredDefaults)

        if let raw = UserDefaults.standard.string(forKey: Keys.asrProvider),
           !["whisperkit", "qwen3-asr-llama"].contains(raw.lowercased()) {
            UserDefaults.standard.set("qwen3-asr-llama", forKey: Keys.asrProvider)
        }
        if let raw = UserDefaults.standard.string(forKey: Keys.correctionBackend),
           CorrectionBackendKind(rawValue: raw) == nil {
            UserDefaults.standard.set(CorrectionBackendKind.qwen35_2B.rawValue, forKey: Keys.correctionBackend)
        }
        if let raw = UserDefaults.standard.string(forKey: Keys.correctionMode),
                  CorrectionMode(rawValue: raw) == nil {
            UserDefaults.standard.set(CorrectionMode.polish.rawValue, forKey: Keys.correctionMode)
        }
        if let raw = UserDefaults.standard.string(forKey: Keys.numberOutputPreference),
           NumberOutputPreference(rawValue: raw) == nil {
            UserDefaults.standard.set(NumberOutputPreference.automatic.rawValue, forKey: Keys.numberOutputPreference)
        }
        if let raw = UserDefaults.standard.string(forKey: Keys.punctuationPreference),
           PunctuationOutputPreference(rawValue: raw) == nil {
            UserDefaults.standard.set(PunctuationOutputPreference.normal.rawValue, forKey: Keys.punctuationPreference)
        }
        if let raw = UserDefaults.standard.string(forKey: Keys.processingMode),
           ProcessingMode(rawValue: raw) == nil {
            UserDefaults.standard.set(ProcessingMode.client.rawValue, forKey: Keys.processingMode)
        }
        if persistedObject(forKey: Keys.bridgeAuthToken) == nil {
            _ = ensureBridgeAuthToken()
        }
    }

    private static func persistedObject(forKey key: String) -> Any? {
        let domainName = Bundle.main.bundleIdentifier ?? currentMacDefaultsDomain
        return UserDefaults.standard.persistentDomain(forName: domainName)?[key]
    }

    // MARK: - Service-side accessors

    private static var ud: UserDefaults { .standard }

    static let serverScopedSettingKeys: [String] = [
        Keys.asrProvider,
        Keys.asrModel,
        Keys.asrLanguageIDs,
        Keys.asrUnloadAfterMin,
        Keys.asrWhisperKitTimeoutSec,
        Keys.asrQwenLlamaTimeoutSec,
        Keys.asrQwenLlamaModelID,
        Keys.asrQwenLlamaMaxTokens,
        Keys.asrQwenLlamaModelPath,
        Keys.asrQwenLlamaMMProjPath,
        Keys.asrQwenLlamaModelDownloadURL,
        Keys.asrQwenLlamaMMProjDownloadURL,
        Keys.correctionBackend,
        Keys.correctionTimeoutMs,
        Keys.correctionColdTimeoutMs,
        Keys.correctionMaxTokens,
        Keys.correctionContextSize,
        Keys.correctionMode,
        Keys.correctionAutoCommit,
        Keys.numberOutputPreference,
        Keys.punctuationPreference,
        Keys.llama2BPath,
        Keys.llama4BPath,
        Keys.llama9BPath,
        Keys.llama2BDownloadURL,
        Keys.llama4BDownloadURL,
        Keys.llama9BDownloadURL,
        Keys.llamaUseFlashAttn,
        Keys.lmStudioBaseURL,
        Keys.lmStudioAPIKey,
        Keys.lmStudioModel,
        Keys.promptOverrideFolder,
        Keys.promptAdditionalSystem,
        Keys.bridgeEnabled,
        Keys.bridgeLANEnabled,
        Keys.bridgeLANAdapter,
        Keys.bridgePublicEnabled,
        Keys.bridgePort,
        Keys.bridgeAuthToken,
        Keys.bridgeHostname,
        Keys.diagnosticsDebugMode,
        Keys.diagnosticsDebugCaptureLimit,
    ] + QwenASRModelCatalog.all.flatMap {
        [$0.modelPathKey, $0.mmprojPathKey, $0.modelURLKey, $0.mmprojURLKey]
    }

    static let clientScopedSettingKeys: [String] = [
        Keys.clientLocalBridgeURLs,
        Keys.clientCloudBridgeURL,
        Keys.clientBridgeToken,
        Keys.clientLanguageIDs,
    ]

    static var maxRecordingDuration: TimeInterval     { ud.double(forKey: Keys.maxRecordingDuration) }
    static var alwaysShowHUD: Bool                    { ud.bool(forKey: Keys.alwaysShowHUD) }
    static var holdModifier: HoldModifier {
        if let raw = ud.string(forKey: Keys.holdModifier),
           let m = HoldModifier(rawValue: raw) { return m }
        return .rightOption
    }

    static var asrProvider: String {
        let raw = ud.string(forKey: Keys.asrProvider)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard raw == "whisperkit" || raw == "qwen3-asr-llama" else { return "qwen3-asr-llama" }
        return raw!
    }
    static var asrModel: String                       { ud.string(forKey: Keys.asrModel) ?? "large-v3-v20240930_626MB" }
    static var asrLanguageIDs: [String] {
        ASRLanguageSelection.parse(
            ud.string(forKey: Keys.asrLanguageIDs) ?? ASRLanguageSelection.defaultRawValue,
            provider: asrProvider
        )
    }
    static var asrLocale: String                      { ASRLanguageSelection.primaryLanguageID(for: asrLanguageIDs) }
    static var asrUnloadAfterMinutes: Int             { ud.integer(forKey: Keys.asrUnloadAfterMin) }
    static var asrWhisperKitTimeoutSeconds: TimeInterval {
        max(10, ud.double(forKey: Keys.asrWhisperKitTimeoutSec))
    }
    static var asrQwenLlamaTimeoutSeconds: TimeInterval {
        max(10, ud.double(forKey: Keys.asrQwenLlamaTimeoutSec))
    }
    static var asrQwenLlamaModelPath: String {
        let spec = QwenASRModelCatalog.spec(for: asrQwenLlamaModelID)
        let value = ud.string(forKey: spec.modelPathKey) ?? spec.defaultModelPath
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? spec.defaultModelPath : trimmed
    }
    static var asrQwenLlamaMMProjPath: String {
        let spec = QwenASRModelCatalog.spec(for: asrQwenLlamaModelID)
        let value = ud.string(forKey: spec.mmprojPathKey) ?? spec.defaultMMProjPath
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? spec.defaultMMProjPath : trimmed
    }
    static var asrQwenLlamaModelID: String {
        let raw = ud.string(forKey: Keys.asrQwenLlamaModelID) ?? QwenASRModelCatalog.defaultID
        return QwenASRModelCatalog.spec(for: raw).id
    }
    static var asrQwenLlamaMaxTokens: Int {
        min(max(128, ud.integer(forKey: Keys.asrQwenLlamaMaxTokens)), 8192)
    }
    static var asrQwenLlamaModelDownloadURL: String {
        let spec = QwenASRModelCatalog.spec(for: asrQwenLlamaModelID)
        return ud.string(forKey: spec.modelURLKey) ?? spec.defaultModelURL
    }
    static var asrQwenLlamaMMProjDownloadURL: String {
        let spec = QwenASRModelCatalog.spec(for: asrQwenLlamaModelID)
        return ud.string(forKey: spec.mmprojURLKey) ?? spec.defaultMMProjURL
    }

    static var correctionBackend: CorrectionBackendKind {
        if let raw = ud.string(forKey: Keys.correctionBackend),
           let kind = CorrectionBackendKind(rawValue: raw) { return kind }
        return .qwen35_2B
    }
    static var correctionTimeoutMs: Int     { max(100, ud.integer(forKey: Keys.correctionTimeoutMs)) }
    static var correctionColdTimeoutMs: Int { max(1000, ud.integer(forKey: Keys.correctionColdTimeoutMs)) }
    static var correctionMaxTokens: Int     { max(16, ud.integer(forKey: Keys.correctionMaxTokens)) }
    static var correctionContextSize: Int   { max(512, ud.integer(forKey: Keys.correctionContextSize)) }
    static var correctionMode: CorrectionMode {
        if let raw = ud.string(forKey: Keys.correctionMode),
           let value = CorrectionMode(rawValue: raw) {
            return value
        }
        return .polish
    }
    static var autoCommit: Bool         { ud.bool(forKey: Keys.correctionAutoCommit) }
    static var numberOutputPreference: NumberOutputPreference {
        NumberOutputPreference.normalized(ud.string(forKey: Keys.numberOutputPreference))
    }
    static var punctuationPreference: PunctuationOutputPreference {
        PunctuationOutputPreference.normalized(ud.string(forKey: Keys.punctuationPreference))
    }
    static var diagnosticsDebugCaptureLimit: Int {
        min(200, max(1, ud.integer(forKey: Keys.diagnosticsDebugCaptureLimit)))
    }
    static var llama2BPath: String        { ud.string(forKey: Keys.llama2BPath) ?? AppPaths.llama2BFile.path }
    static var llama4BPath: String        { ud.string(forKey: Keys.llama4BPath) ?? AppPaths.llama4BFile.path }
    static var llama9BPath: String        { ud.string(forKey: Keys.llama9BPath) ?? AppPaths.llama9BFile.path }
    static var llama2BDownloadURL: String { ud.string(forKey: Keys.llama2BDownloadURL) ?? "" }
    static var llama4BDownloadURL: String { ud.string(forKey: Keys.llama4BDownloadURL) ?? "" }
    static var llama9BDownloadURL: String { ud.string(forKey: Keys.llama9BDownloadURL) ?? "" }
    static var llamaUseFlashAttn: Bool  { ud.bool(forKey: Keys.llamaUseFlashAttn) }
    static var lmStudioBaseURL: String {
        let value = ud.string(forKey: Keys.lmStudioBaseURL) ?? "http://127.0.0.1:1234/v1"
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "http://127.0.0.1:1234/v1" : trimmed
    }
    static var lmStudioAPIKey: String {
        ud.string(forKey: Keys.lmStudioAPIKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static var lmStudioModel: String {
        ud.string(forKey: Keys.lmStudioModel)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var promptOverrideFolder: URL {
        URL(fileURLWithPath: ud.string(forKey: Keys.promptOverrideFolder) ?? AppPaths.promptsDir.path)
    }
    static var promptAdditionalSystem: String {
        ud.string(forKey: Keys.promptAdditionalSystem) ?? ""
    }

    static var processingMode: ProcessingMode {
        processingMode(in: ud)
    }

    static func setProcessingMode(_ target: ProcessingMode) {
        setProcessingMode(target, defaults: ud)
    }

    static func setProcessingMode(_ target: ProcessingMode, defaults: UserDefaults) {
        let current = processingMode(in: defaults)
        guard current != target else { return }

        saveScopedSettings(for: current, defaults: defaults)
        defaults.set(target.rawValue, forKey: Keys.processingMode)
        restoreScopedSettings(for: target, defaults: defaults)
        defaults.synchronize()
    }

    private static func processingMode(in defaults: UserDefaults) -> ProcessingMode {
        if let raw = defaults.string(forKey: Keys.processingMode),
           let mode = ProcessingMode(rawValue: raw) {
            return mode
        }
        return .client
    }

    private static func saveScopedSettings(for mode: ProcessingMode, defaults: UserDefaults) {
        let keys = scopedSettingKeys(for: mode)
        var snapshot: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) {
                snapshot[key] = value
            }
        }
        defaults.set(snapshot, forKey: snapshotKey(for: mode))
    }

    private static func restoreScopedSettings(for mode: ProcessingMode, defaults: UserDefaults) {
        guard let snapshot = defaults.dictionary(forKey: snapshotKey(for: mode)) else { return }
        for key in scopedSettingKeys(for: mode) {
            if let value = snapshot[key] {
                defaults.set(value, forKey: key)
            }
        }
    }

    private static func scopedSettingKeys(for mode: ProcessingMode) -> [String] {
        switch mode {
        case .server: return serverScopedSettingKeys
        case .client: return clientScopedSettingKeys
        }
    }

    private static func snapshotKey(for mode: ProcessingMode) -> String {
        switch mode {
        case .server: return Keys.serverSettingsSnapshot
        case .client: return Keys.clientSettingsSnapshot
        }
    }
    static var clientLocalBridgeURLsRaw: String {
        ud.string(forKey: Keys.clientLocalBridgeURLs) ?? ""
    }
    static var clientLocalBridgeURLs: [String] {
        ClientBridgeConfiguration.uniqueBridgeURLs(
            clientLocalBridgeURLsRaw
                .components(separatedBy: CharacterSet(charactersIn: "\n,"))
        )
    }
    static var clientCloudBridgeURL: String {
        ud.string(forKey: Keys.clientCloudBridgeURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static var clientBridgeToken: String {
        ud.string(forKey: Keys.clientBridgeToken)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static var clientLanguageIDs: [String] {
        ASRLanguageSelection.parse(
            ud.string(forKey: Keys.clientLanguageIDs) ?? ASRLanguageSelection.defaultRawValue
        )
    }

    static var activeLanguageIDs: [String] {
        processingMode == .client ? clientLanguageIDs : asrLanguageIDs
    }

    static var bridgeEnabled: Bool    { ud.bool(forKey: Keys.bridgeEnabled) }
    static var bridgeLANEnabled: Bool { ud.bool(forKey: Keys.bridgeLANEnabled) }
    static var bridgeLANAdapter: String {
        let value = ud.string(forKey: Keys.bridgeLANAdapter)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "all"
        return value.isEmpty ? "all" : value
    }
    static var bridgePublicEnabled: Bool { ud.bool(forKey: Keys.bridgePublicEnabled) }
    static var bridgePort: Int        { max(1024, ud.integer(forKey: Keys.bridgePort)) }
    static var bridgeHostname: String {
        ud.string(forKey: Keys.bridgeHostname) ?? ""
    }
    static var diagnosticsDebugMode: Bool {
        ud.bool(forKey: Keys.diagnosticsDebugMode)
    }
    static var bridgeAuthToken: String {
        ensureBridgeAuthToken()
    }

    @discardableResult
    static func ensureBridgeAuthToken() -> String {
        if let token = ud.string(forKey: Keys.bridgeAuthToken),
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return token
        }
        let token = newBridgeAuthToken()
        ud.set(token, forKey: Keys.bridgeAuthToken)
        return token
    }

    @discardableResult
    static func rotateBridgeAuthToken() -> String {
        let token = newBridgeAuthToken()
        ud.set(token, forKey: Keys.bridgeAuthToken)
        return token
    }

    private static func newBridgeAuthToken() -> String {
        newLocalToken()
    }

    private static func newLocalToken() -> String {
        [UUID().uuidString, UUID().uuidString]
            .joined(separator: "")
            .replacingOccurrences(of: "-", with: "")
    }
}

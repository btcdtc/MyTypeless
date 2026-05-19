import Foundation
import Testing
@testable import Typeforme

@Suite("ProcessingModeSettings")
struct ProcessingModeSettingsTests {
    @Test func switchingModesRestoresServerAndClientScopedSettings() {
        let suiteName = "TypeformeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(ProcessingMode.server.rawValue, forKey: AppSettings.Keys.processingMode)
        defaults.set(CorrectionBackendKind.qwen35_9B.rawValue, forKey: AppSettings.Keys.correctionBackend)
        defaults.set(true, forKey: AppSettings.Keys.bridgeEnabled)
        defaults.set("http://192.168.1.10:18081", forKey: AppSettings.Keys.clientLocalBridgeURLs)
        defaults.set("https://old.example.com", forKey: AppSettings.Keys.clientCloudBridgeURL)
        defaults.set("old-token", forKey: AppSettings.Keys.clientBridgeToken)
        defaults.set("en,zh", forKey: AppSettings.Keys.clientLanguageIDs)

        AppSettings.setProcessingMode(.client, defaults: defaults)
        defaults.set("http://192.168.1.20:18081", forKey: AppSettings.Keys.clientLocalBridgeURLs)
        defaults.set("https://client.example.com", forKey: AppSettings.Keys.clientCloudBridgeURL)
        defaults.set("client-token", forKey: AppSettings.Keys.clientBridgeToken)
        defaults.set("ja,vi", forKey: AppSettings.Keys.clientLanguageIDs)
        defaults.set(CorrectionBackendKind.qwen35_2B.rawValue, forKey: AppSettings.Keys.correctionBackend)
        defaults.set(false, forKey: AppSettings.Keys.bridgeEnabled)

        AppSettings.setProcessingMode(.server, defaults: defaults)
        #expect(defaults.string(forKey: AppSettings.Keys.processingMode) == ProcessingMode.server.rawValue)
        #expect(defaults.string(forKey: AppSettings.Keys.correctionBackend) == CorrectionBackendKind.qwen35_9B.rawValue)
        #expect(defaults.bool(forKey: AppSettings.Keys.bridgeEnabled))

        AppSettings.setProcessingMode(.client, defaults: defaults)
        #expect(defaults.string(forKey: AppSettings.Keys.processingMode) == ProcessingMode.client.rawValue)
        #expect(defaults.string(forKey: AppSettings.Keys.clientLocalBridgeURLs) == "http://192.168.1.20:18081")
        #expect(defaults.string(forKey: AppSettings.Keys.clientCloudBridgeURL) == "https://client.example.com")
        #expect(defaults.string(forKey: AppSettings.Keys.clientBridgeToken) == "client-token")
        #expect(defaults.string(forKey: AppSettings.Keys.clientLanguageIDs) == "ja,vi")
    }
}

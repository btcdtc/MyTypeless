import Foundation

@MainActor
final class ClientBridgeSettingsSync {
    private static let minimumSyncInterval: TimeInterval = 60

    private var lastSyncAt: Date?
    private var syncTask: Task<Void, Never>?

    func syncIfNeeded(force: Bool = false) {
        guard AppSettings.processingMode == .client else { return }
        guard ClientBridgeConfiguration.current.isConfigured else { return }
        if !force,
           let lastSyncAt,
           Date().timeIntervalSince(lastSyncAt) < Self.minimumSyncInterval {
            return
        }
        guard syncTask == nil else { return }

        syncTask = Task { [weak self] in
            await self?.sync()
        }
    }

    func cancel() {
        syncTask?.cancel()
        syncTask = nil
    }

    static func applyServerDefaults(_ settings: BridgeSettingsPayload) {
        if CorrectionMode(rawValue: settings.correctionMode) != nil {
            UserDefaults.standard.set(settings.correctionMode, forKey: AppSettings.Keys.correctionMode)
        }

        let supported = settings.supportedLanguageOptions(for: settings.asrProvider)
        let validated = ASRLanguageSelection.validatedIDs(AppSettings.clientLanguageIDs, supportedOptions: supported)
        UserDefaults.standard.set(
            ASRLanguageSelection.rawValue(for: validated, supportedOptions: supported),
            forKey: AppSettings.Keys.clientLanguageIDs
        )
    }

    private func sync() async {
        defer { syncTask = nil }

        do {
            let resolved = try await RemoteBridgeClient.resolvedFromSettings(probeAllEndpoints: true)
            var settings = try await resolved.client.settings(timeout: 6)
            settings.normalize()
            Self.applyServerDefaults(settings)
            lastSyncAt = Date()
            Log.bridge.info("Client bridge settings synced via \(resolved.routeStatus.activeKind.rawValue, privacy: .public)")
        } catch {
            if !Task.isCancelled {
                Log.bridge.debug("Client bridge settings sync skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

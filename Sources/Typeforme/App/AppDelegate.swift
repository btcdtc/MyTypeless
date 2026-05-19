import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator: DictationCoordinator
    let dictionary: UserDictionaryStore
    let settingsWindow: SettingsWindowController
    private let bridgeServer: BridgeHTTPServer
    private let clientSettingsSync = ClientBridgeSettingsSync()
    private var hud: HUDWindowController!
    private let comboHotkey = HotkeyManager()
    private let commandTextEditHotkey = HotkeyManager(name: .commandTextEdit)
    private let holdMonitor = DoubleTapModifierMonitor()
    private var cancellables: Set<AnyCancellable> = []
    private var escMonitor: Any?
    private var enterMonitor: Any?
    private var comboHotkeyIsDown = false
    private var commandTextEditHotkeyIsDown = false
    private var comboHotkeyReleaseWatchdog: Task<Void, Never>?
    private static let comboHotkeyReleaseWatchdogDelay: UInt64 = 1_500_000_000
    private var lastComboHotkeyPressAt: Date?
    private var lastCommandTextEditHotkeyPressAt: Date?
    private static let hotkeyBounceWindow: TimeInterval = 0.35

    override init() {
        AppSettings.registerDefaults()
        try? AppPaths.ensureDirectories()
        let store = UserDictionaryStore()
        self.dictionary     = store
        self.coordinator    = DictationCoordinator(dictionary: store)
        self.settingsWindow = SettingsWindowController(dictionary: store)
        self.bridgeServer   = BridgeHTTPServer(dictionary: store)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard SingleInstanceGuard.shared.acquireOrActivateExisting() else {
            NSApp.terminate(nil)
            return
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        hud = HUDWindowController(coordinator: coordinator)

        // HUD visibility: show whenever something's happening, OR whenever
        // the user has flipped on "Always show HUD" (Settings or menu bar).
        let alwaysShowChanges = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in AppSettings.alwaysShowHUD }
            .prepend(AppSettings.alwaysShowHUD)
            .removeDuplicates()

        Publishers.CombineLatest(
            coordinator.$state.removeDuplicates(),
            alwaysShowChanges
        )
        .sink { [weak self] state, alwaysShow in
            guard let self else { return }
            if state == .idle && !alwaysShow {
                self.hud.hide()
            } else {
                self.hud.show()
            }
        }
        .store(in: &cancellables)

        // Combo shortcut → toggle (industry standard for combos). Key-down can
        // repeat while held, so we ignore repeats until key-up. A watchdog
        // clears the latch if macOS drops the key-up during a focus change.
        comboHotkey.onPressed = { [weak self] in self?.handleTogglePress() }
        comboHotkey.onReleased = { [weak self] in self?.handleToggleRelease() }
        comboHotkey.install()

        commandTextEditHotkey.onPressed = { [weak self] in self?.handleCommandTextEditPress() }
        commandTextEditHotkey.onReleased = { [weak self] in self?.handleCommandTextEditRelease() }
        commandTextEditHotkey.install()

        // Double-tap modifier → hold-to-talk
        holdMonitor.onHoldStart = { [weak self] in self?.handleHoldStart() }
        holdMonitor.onHoldEnd   = { [weak self] in self?.handleHoldEnd() }
        holdMonitor.install(modifier: AppSettings.holdModifier)

        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in AppSettings.holdModifier }
            .removeDuplicates()
            .sink { [weak self] modifier in
                self?.holdMonitor.install(modifier: modifier)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                if AppSettings.processingMode == .server {
                    self?.bridgeServer.applySettings()
                } else {
                    self?.bridgeServer.stop()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in AppSettings.processingMode }
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.applyProcessingMode(mode)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.clientSettingsSync.syncIfNeeded()
            }
            .store(in: &cancellables)

        installEscMonitor()

        // Enter in .preview state → commit the previewed text at the current
        // cursor. Monitor is installed only while the HUD shows preview so
        // we don't observe every Enter keypress on the system.
        coordinator.$state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .preview {
                    self?.installEnterMonitor()
                } else {
                    self?.removeEnterMonitor()
                }
            }
            .store(in: &cancellables)

        if !AccessibilityPermissions.isTrusted {
            Log.app.notice("AX trust not granted; paste insertion will fail until granted")
        }
        applyProcessingMode(AppSettings.processingMode)
        clientSettingsSync.syncIfNeeded(force: true)
        Log.app.info("Typeforme launched (accessory mode)")
    }

    /// Spec §12: stop any owned llama-server subprocess before the system
    /// kills the app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator.shutdown()
        bridgeServer.stop()
        Task { @MainActor in
            await ASRFactory.shared.stopQwenLlama()
            await CorrectorFactory.shared.shutdownAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridgeServer.stop()
        clientSettingsSync.cancel()
        holdMonitor.uninstall()
        comboHotkeyReleaseWatchdog?.cancel()
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        removeEnterMonitor()
    }

    /// Exposed for the SwiftUI MenuBarMenu's Settings button.
    func openSettings() {
        settingsWindow.show()
    }

    // MARK: - Hotkey dispatch

    private func handleTogglePress() {
        if comboHotkeyIsDown {
            Log.hotkey.debug("toggle repeated key-down ignored")
            return
        }
        let now = Date()
        if let lastComboHotkeyPressAt,
           now.timeIntervalSince(lastComboHotkeyPressAt) < Self.hotkeyBounceWindow {
            Log.hotkey.debug("toggle bounced key-down ignored")
            comboHotkeyIsDown = true
            armComboHotkeyReleaseWatchdog()
            return
        }
        lastComboHotkeyPressAt = now
        comboHotkeyIsDown = true
        armComboHotkeyReleaseWatchdog()
        Task { @MainActor in
            await coordinator.toggleDictation()
        }
    }

    private func handleToggleRelease() {
        comboHotkeyIsDown = false
        comboHotkeyReleaseWatchdog?.cancel()
        comboHotkeyReleaseWatchdog = nil
    }

    private func handleCommandTextEditPress() {
        if commandTextEditHotkeyIsDown { return }
        let now = Date()
        if let lastCommandTextEditHotkeyPressAt,
           now.timeIntervalSince(lastCommandTextEditHotkeyPressAt) < Self.hotkeyBounceWindow {
            Log.hotkey.debug("command edit bounced key-down ignored")
            return
        }
        lastCommandTextEditHotkeyPressAt = now
        commandTextEditHotkeyIsDown = true
        Task { @MainActor in
            await coordinator.toggleCommandTextEdit()
        }
    }

    private func handleCommandTextEditRelease() {
        commandTextEditHotkeyIsDown = false
    }

    private func armComboHotkeyReleaseWatchdog() {
        comboHotkeyReleaseWatchdog?.cancel()
        let delay = Self.comboHotkeyReleaseWatchdogDelay
        comboHotkeyReleaseWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.comboHotkeyIsDown else { return }
                self.comboHotkeyIsDown = false
                self.comboHotkeyReleaseWatchdog = nil
                Log.hotkey.debug("toggle key-up watchdog reset")
            }
        }
    }

    private func handleHoldStart() {
        Task { @MainActor in
            if coordinator.state == .idle {
                await coordinator.startDictation()
            }
        }
    }

    private func handleHoldEnd() {
        Task { @MainActor in
            if coordinator.state == .recording {
                await coordinator.stopDictation()
            }
        }
    }

    // MARK: - Esc cancel (spec §8)

    private func installEscMonitor() {
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }  // kVK_Escape
            guard let self else { return }
            Task { @MainActor in
                if self.coordinator.state != .idle {
                    Log.app.debug("Esc — cancelling dictation")
                    await self.coordinator.cancelDictation()
                }
            }
        }
    }

    private func installEnterMonitor() {
        guard enterMonitor == nil else { return }
        enterMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Plain Return / numpad Enter only; Cmd/Shift/Opt+Enter stays
            // with the foreground app (newline, send, etc.).
            guard event.keyCode == 36 || event.keyCode == 76 else { return }
            let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
            guard mods.isEmpty else { return }
            guard let self else { return }
            Task { @MainActor in
                guard self.coordinator.state == .preview else { return }
                Log.app.debug("Enter — committing preview")
                await self.coordinator.commitPreview()
            }
        }
    }

    private func removeEnterMonitor() {
        if let m = enterMonitor {
            NSEvent.removeMonitor(m)
            enterMonitor = nil
        }
    }

    private func preloadRuntimeModels() {
        guard AppSettings.processingMode == .server else {
            Log.app.info("Skipping local model preload in client mode")
            return
        }
        Task { @MainActor in
            async let asrPreload: Void = ASRFactory.shared.preloadCachedActiveModel()
            async let correctionPreload: CorrectorPreloadResult = CorrectorFactory.shared.preloadActiveModels()
            _ = await (asrPreload, correctionPreload)
        }
    }

    private func applyProcessingMode(_ mode: ProcessingMode) {
        switch mode {
        case .server:
            bridgeServer.applySettings()
            preloadRuntimeModels()
        case .client:
            bridgeServer.stop()
            clientSettingsSync.syncIfNeeded(force: true)
            Task { @MainActor in
                await ASRFactory.shared.stopQwenLlama()
                await CorrectorFactory.shared.shutdownAll()
            }
        }
    }
}

import SwiftUI
import KeyboardShortcuts
import AppKit

private struct IntegerSettingField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let suffix: String

    @State private var draft = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer()
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 96)
                .onAppear(perform: syncFromValue)
                .onSubmit(commitDraft)
                .onChange(of: draft) { _, newValue in
                    let filtered = newValue.filter { $0.isWholeNumber }
                    if filtered != newValue {
                        draft = filtered
                        return
                    }
                    if let parsed = Int(filtered), range.contains(parsed) {
                        value = parsed
                    }
                }
                .onChange(of: value) { _, newValue in
                    let clamped = clamp(newValue)
                    if clamped != newValue {
                        value = clamped
                        return
                    }
                    if Int(draft) != clamped {
                        draft = String(clamped)
                    }
                }
            if !suffix.isEmpty {
                Text(suffix)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commitDraft() {
        let parsed = Int(draft) ?? value
        let clamped = clamp(parsed)
        value = clamped
        draft = String(clamped)
    }

    private func syncFromValue() {
        let clamped = clamp(value)
        if clamped != value {
            value = clamped
        }
        draft = String(clamped)
    }

    private func clamp(_ value: Int) -> Int {
        min(max(range.lowerBound, value), range.upperBound)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage(AppSettings.Keys.processingMode) private var processingModeRaw = ProcessingMode.client.rawValue
    @State private var axTrusted = AccessibilityPermissions.isTrusted
    @State private var microphoneStatus = AppPermissions.microphoneStatus
    @State private var localNetworkCheck = LocalNetworkPermissionCheck.notChecked

    var body: some View {
        Form {
            Section("App") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion()).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Bundle ID")
                    Spacer()
                    Text(Bundle.main.bundleIdentifier ?? "—")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section("Role") {
                Picker("This Mac", selection: processingModeBinding) {
                    ForEach(ProcessingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(processingMode.helpText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Permissions") {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    Text(axTrusted ? "Granted" : "Not granted")
                        .foregroundStyle(axTrusted ? .green : .orange)
                    if !axTrusted {
                        Button("Open System Settings…") {
                            AccessibilityPermissions.openAccessibilitySettings()
                        }
                    }
                    Menu {
                        Button("Refresh now") {
                            axTrusted = AccessibilityPermissions.isTrusted
                        }
                        Button("Reset & re-prompt") {
                            // tccutil reset wipes the record but doesn't re-register
                            // us in the Accessibility list; we have to "knock" via
                            // AXIsProcessTrustedWithOptions(prompt:true) to make
                            // macOS add Typeforme back so there's something to toggle.
                            _ = AccessibilityPermissions.resetGrant()
                            AccessibilityPermissions.requestTrustPrompt()
                            axTrusted = AccessibilityPermissions.isTrusted
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Text(axTrusted
                     ? "Typeforme can paste corrected text via synthesized ⌘V."
                     : "Toggle Typeforme on in System Settings → Privacy → Accessibility. This row refreshes automatically once you grant access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !axTrusted {
                    Text("Still says \"Not granted\" after toggling? This local build is adhoc-signed, so each rebuild looks like a different app to macOS. Try \"Reset & re-prompt\" to clear the stale TCC record, then grant once more. Run scripts/create-signing-identity.sh once to make grants stick across rebuilds.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("Microphone")
                    Spacer()
                    Text(microphoneStatusText)
                        .foregroundStyle(microphoneStatusColor)
                    if microphoneStatus == .notDetermined {
                        Button("Request Access") {
                            Task {
                                microphoneStatus = await AppPermissions.requestMicrophone()
                            }
                        }
                    } else if microphoneStatus != .granted {
                        Button("Open System Settings…") {
                            AppPermissions.openMicrophoneSettings()
                        }
                    }
                    Button("Refresh") {
                        microphoneStatus = AppPermissions.microphoneStatus
                    }
                }
                Text(microphoneHelpText)
                    .font(.footnote)
                    .foregroundStyle(microphoneHelpColor)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Local Network")
                    Spacer()
                    Text(localNetworkStatusText)
                        .foregroundStyle(localNetworkStatusColor)
                    Button(localNetworkCheck.status == .checking ? "Checking" : "Check") {
                        Task { await checkLocalNetworkPermission() }
                    }
                    .disabled(localNetworkCheck.status == .checking)
                    Button("Open System Settings…") {
                        AppPermissions.openLocalNetworkSettings()
                    }
                }
                Text(localNetworkHelpText)
                    .font(.footnote)
                    .foregroundStyle(localNetworkHelpColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // Poll while Settings is visible so the state flips to "Granted"
        // the moment the user toggles it in System Settings → Privacy.
        .task {
            while !Task.isCancelled {
                let now = AccessibilityPermissions.isTrusted
                if now != axTrusted { axTrusted = now }
                let mic = AppPermissions.microphoneStatus
                if mic != microphoneStatus { microphoneStatus = mic }
                if localNetworkCheck.status == .notChecked {
                    await checkLocalNetworkPermission()
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        // Belt-and-braces: also re-check the instant the user switches back
        // to Typeforme after granting in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = AccessibilityPermissions.isTrusted
            microphoneStatus = AppPermissions.microphoneStatus
            Task { await checkLocalNetworkPermission() }
        }
    }

    private func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }

    private var processingMode: ProcessingMode {
        ProcessingMode(rawValue: processingModeRaw) ?? .client
    }

    private var processingModeBinding: Binding<String> {
        Binding {
            processingModeRaw
        } set: { raw in
            guard let mode = ProcessingMode(rawValue: raw) else { return }
            AppSettings.setProcessingMode(mode)
            processingModeRaw = AppSettings.processingMode.rawValue
        }
    }

    private var microphoneStatusText: String {
        switch microphoneStatus {
        case .granted: return "Granted"
        case .notDetermined: return "Not requested"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .unknown: return "Unknown"
        }
    }

    private var microphoneStatusColor: Color {
        switch microphoneStatus {
        case .granted: return .green
        case .notDetermined: return .orange
        case .denied, .restricted, .unknown: return .red
        }
    }

    private var microphoneHelpText: String {
        switch microphoneStatus {
        case .granted:
            return "Typeforme can record dictation audio on this Mac."
        case .notDetermined:
            return "Grant Microphone access before recording locally."
        case .denied:
            return "Enable Typeforme in System Settings → Privacy & Security → Microphone."
        case .restricted:
            return "Microphone access is restricted by system policy."
        case .unknown:
            return "Microphone permission state could not be read."
        }
    }

    private var microphoneHelpColor: Color {
        microphoneStatus == .granted ? Color.secondary : Color.orange
    }

    private var localNetworkStatusText: String {
        switch localNetworkCheck.status {
        case .notChecked: return "Not checked"
        case .checking: return "Checking"
        case .reachable: return "Reachable"
        case .notRequired: return "Not required"
        case .noLocalTarget: return "No LAN target"
        case .blockedOrUnreachable: return "Blocked or unreachable"
        }
    }

    private var localNetworkStatusColor: Color {
        switch localNetworkCheck.status {
        case .reachable, .notRequired: return .green
        case .notChecked, .checking, .noLocalTarget: return .orange
        case .blockedOrUnreachable: return .red
        }
    }

    private var localNetworkHelpText: String {
        let prefix = localNetworkCheck.targetDescription.isEmpty
            ? ""
            : "\(localNetworkCheck.targetDescription): "
        return prefix + localNetworkCheck.detail
    }

    private var localNetworkHelpColor: Color {
        localNetworkCheck.status == .reachable || localNetworkCheck.status == .notRequired
            ? Color.secondary
            : Color.orange
    }

    private func checkLocalNetworkPermission() async {
        localNetworkCheck = .checking
        localNetworkCheck = await AppPermissions.checkLocalNetwork()
    }
}

// MARK: - Client Server

struct ClientServerSettingsView: View {
    @AppStorage(AppSettings.Keys.clientLocalBridgeURLs) private var clientLocalBridgeURLsRaw = ""
    @AppStorage(AppSettings.Keys.clientCloudBridgeURL) private var clientCloudBridgeURL = ""
    @AppStorage(AppSettings.Keys.clientBridgeToken) private var clientBridgeToken = ""
    @AppStorage(AppSettings.Keys.clientLanguageIDs) private var clientLanguageIDsRaw = ASRLanguageSelection.defaultRawValue
    @State private var draft: BridgeSettingsPayload?
    @State private var isChecking = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var showAllClientLanguages = false
    @State private var showAllServerLanguages = false
    @State private var routeStatus = ClientBridgeRouteStatus()

    var body: some View {
        Form {
            Section("Connection") {
                HStack {
                    Button {
                        pastePairingJSON()
                    } label: {
                        Label("Paste Pairing JSON", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        Task { await checkRoutes() }
                    } label: {
                        Label(isChecking ? "Checking…" : "Check Routes", systemImage: "network")
                    }
                    .disabled(isChecking || !clientConfig.isConfigured)
                    Spacer()
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(statusIsError ? .orange : .green)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Local URLs")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $clientLocalBridgeURLsRaw)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 54)
                        .scrollContentBackground(.hidden)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                        )
                }

                TextField("Cloud URL", text: $clientCloudBridgeURL, prompt: Text("https://voice.example.com"))
                    .textFieldStyle(.roundedBorder)
                SecureField("Bearer token", text: $clientBridgeToken)
                    .textFieldStyle(.roundedBorder)

                ClientRouteRow(
                    title: "Local",
                    endpoint: primaryLocalEndpoint,
                    state: endpointState(
                        isConfigured: !clientConfig.localBridgeURLs.isEmpty,
                        isChecked: routeStatus.localChecked,
                        isOK: routeStatus.localOK
                    ),
                    latencyMs: routeStatus.localLatencyMs,
                    isActive: routeStatus.activeKind == .local,
                    tint: .green
                )
                ClientRouteRow(
                    title: "Cloud",
                    endpoint: cloudEndpoint,
                    state: endpointState(
                        isConfigured: !clientConfig.cloudBridgeURL.isEmpty,
                        isChecked: routeStatus.cloudChecked,
                        isOK: routeStatus.cloudOK
                    ),
                    latencyMs: routeStatus.cloudLatencyMs,
                    isActive: routeStatus.activeKind == .cloud,
                    tint: .blue
                )

                Text("Client mode records on this Mac, sends audio to Typeforme Bridge, then inserts the returned text locally. Requests try Local first and fall back to Cloud only when Local is unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Client Input") {
                Text(clientLanguageSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                clientLanguageGrid(commonClientLanguageOptions)

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showAllClientLanguages.toggle()
                    }
                } label: {
                    DisclosureRow(
                        title: "All client languages",
                        count: allOtherClientLanguages.count,
                        isExpanded: showAllClientLanguages
                    )
                }
                .buttonStyle(.plain)

                if showAllClientLanguages {
                    clientLanguageGrid(allOtherClientLanguages)
                        .padding(.top, 2)
                }

                if let current = draft {
                    LabeledContent("Default mode") {
                        Text(CorrectionMode(rawValue: current.correctionMode)?.displayName ?? current.correctionMode)
                            .foregroundStyle(.secondary)
                    }
                    Text("Languages here are this Mac's local override. Default mode follows Server Settings and is refreshed from the active route.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let current = draft {
                Section("Server Speech") {
                    Picker("ASR Engine", selection: asrProviderBinding) {
                        ForEach(asrProviderOptions(for: current)) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(selectedLanguageSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    serverLanguageGrid(commonServerLanguageOptions)

                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showAllServerLanguages.toggle()
                        }
                    } label: {
                        DisclosureRow(
                            title: "All server languages",
                            count: allOtherServerLanguages.count,
                            isExpanded: showAllServerLanguages
                        )
                    }
                    .buttonStyle(.plain)

                    if showAllServerLanguages {
                        serverLanguageGrid(allOtherServerLanguages)
                            .padding(.top, 2)
                    }
                }

                Section("Server Correction") {
                    Picker("Engine", selection: correctionBackendBinding) {
                        ForEach(correctionBackendOptions(for: current)) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Default mode", selection: correctionModeBinding) {
                        ForEach(CorrectionMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Numbers", selection: numberOutputPreferenceBinding) {
                        ForEach(NumberOutputPreference.allCases) { preference in
                            Text(preference.displayName).tag(preference.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Punctuation", selection: punctuationPreferenceBinding) {
                        ForEach(PunctuationOutputPreference.allCases) { preference in
                            Text(preference.displayName).tag(preference.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("Server local auto-commit", isOn: autoCommitBinding)
                    Toggle("Server debug capture", isOn: debugModeBinding)
                }

                Section {
                    HStack {
                        Button {
                            Task { await saveSettings() }
                        } label: {
                            Label(isSaving ? "Saving…" : "Save to Server", systemImage: "arrow.up.circle")
                        }
                        .disabled(isSaving || isLoading)

                        Button {
                            Task { await loadSettings(force: true) }
                        } label: {
                            Label("Reload from Server", systemImage: "arrow.clockwise")
                        }
                        .disabled(isLoading || isSaving)
                    }
                }
            } else {
                Section("Server Settings") {
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text("Loading server settings")
                        }
                    } else {
                        Button {
                            Task { await loadSettings(force: true) }
                        } label: {
                            Label("Pull Server Settings", systemImage: "arrow.down.circle")
                        }
                        .disabled(!clientConfig.isConfigured)
                    }
                    Text("After pulling, this page shows the active Server ASR, language, correction, default mode, auto-commit, and debug settings returned by /v1/settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await loadSettings(force: false)
        }
    }

    private var asrProviderBinding: Binding<String> {
        Binding {
            draft?.asrProvider ?? "qwen3-asr-llama"
        } set: { value in
            draft?.asrProvider = value
            normalizeDraft()
        }
    }

    private var correctionBackendBinding: Binding<String> {
        Binding {
            draft?.correctionBackend ?? ""
        } set: { value in
            draft?.correctionBackend = value
            normalizeDraft()
        }
    }

    private var correctionModeBinding: Binding<String> {
        Binding {
            draft?.correctionMode ?? CorrectionMode.polish.rawValue
        } set: { value in
            draft?.correctionMode = value
            normalizeDraft()
        }
    }

    private var numberOutputPreferenceBinding: Binding<String> {
        Binding {
            draft?.numberOutputPreference ?? NumberOutputPreference.automatic.rawValue
        } set: { value in
            draft?.numberOutputPreference = value
            normalizeDraft()
        }
    }

    private var punctuationPreferenceBinding: Binding<String> {
        Binding {
            draft?.punctuationPreference ?? PunctuationOutputPreference.normal.rawValue
        } set: { value in
            draft?.punctuationPreference = value
            normalizeDraft()
        }
    }

    private var autoCommitBinding: Binding<Bool> {
        Binding {
            draft?.autoCommit ?? true
        } set: { value in
            draft?.autoCommit = value
        }
    }

    private var debugModeBinding: Binding<Bool> {
        Binding {
            draft?.debugMode ?? false
        } set: { value in
            draft?.debugMode = value
        }
    }

    private var selectedServerLanguageIDs: [String] {
        draft?.languageIDs ?? ASRLanguageSelection.defaultIDs
    }

    private var serverSupportedLanguageOptions: [ASRLanguageOption] {
        guard let draft else { return ASRLanguageSelection.all }
        return draft.supportedLanguageOptions(for: draft.asrProvider)
    }

    private var clientSupportedLanguageOptions: [ASRLanguageOption] {
        serverSupportedLanguageOptions
    }

    private var selectedClientLanguageIDs: [String] {
        ASRLanguageSelection.validatedIDs(
            ASRLanguageSelection.parse(clientLanguageIDsRaw),
            supportedOptions: clientSupportedLanguageOptions
        )
    }

    private var commonServerLanguageOptions: [ASRLanguageOption] {
        serverSupportedLanguageOptions
            .filter(\.isCommon)
            .sorted { ($0.commonRank ?? .max) < ($1.commonRank ?? .max) }
    }

    private var allOtherServerLanguages: [ASRLanguageOption] {
        serverSupportedLanguageOptions.filter { !$0.isCommon }
    }

    private var commonClientLanguageOptions: [ASRLanguageOption] {
        clientSupportedLanguageOptions
            .filter(\.isCommon)
            .sorted { ($0.commonRank ?? .max) < ($1.commonRank ?? .max) }
    }

    private var allOtherClientLanguages: [ASRLanguageOption] {
        clientSupportedLanguageOptions.filter { !$0.isCommon }
    }

    private var languageColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 168), spacing: 10, alignment: .leading)]
    }

    private var selectedLanguageSummary: String {
        "Server default: " + ASRLanguageSelection
            .displayNames(for: selectedServerLanguageIDs, supportedOptions: serverSupportedLanguageOptions)
            .joined(separator: ", ")
    }

    private var clientLanguageSummary: String {
        "Client override: " + ASRLanguageSelection
            .displayNames(for: selectedClientLanguageIDs, supportedOptions: clientSupportedLanguageOptions)
            .joined(separator: ", ")
    }

    private var clientConfig: ClientBridgeConfiguration {
        ClientBridgeConfiguration(
            localBridgeURLs: ClientBridgeConfiguration.uniqueBridgeURLs(
                clientLocalBridgeURLsRaw.components(separatedBy: CharacterSet(charactersIn: "\n,"))
            ),
            cloudBridgeURL: ClientBridgeConfiguration.normalizedBaseURL(clientCloudBridgeURL),
            token: clientBridgeToken
        )
    }

    private var primaryLocalEndpoint: String {
        if routeStatus.activeKind == .local, let activeURL = routeStatus.activeURL?.absoluteString {
            return activeURL
        }
        return clientConfig.localBridgeURLs.first ?? "Not configured"
    }

    private var cloudEndpoint: String {
        clientConfig.cloudBridgeURL.isEmpty ? "Not configured" : clientConfig.cloudBridgeURL
    }

    private func asrProviderOptions(for current: BridgeSettingsPayload) -> [BridgeSettingOption] {
        current.asrProviderOptions.isEmpty
            ? [BridgeSettingOption(id: current.asrProvider, displayName: current.asrProvider)]
            : current.asrProviderOptions
    }

    private func correctionBackendOptions(for current: BridgeSettingsPayload) -> [BridgeSettingOption] {
        current.correctionBackendOptions.isEmpty
            ? [BridgeSettingOption(id: current.correctionBackend, displayName: current.correctionBackend)]
            : current.correctionBackendOptions
    }

    private func serverLanguageGrid(_ options: [ASRLanguageOption]) -> some View {
        LazyVGrid(columns: languageColumns, alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                serverLanguageToggle(option)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func serverLanguageToggle(_ option: ASRLanguageOption) -> some View {
        Toggle(isOn: Binding(
            get: { selectedServerLanguageIDs.contains(option.id) },
            set: { setServerLanguage(option, enabled: $0) }
        )) {
            Text(option.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .toggleStyle(.checkbox)
        .disabled(selectedServerLanguageIDs.contains(option.id) && selectedServerLanguageIDs.count == 1)
    }

    private func clientLanguageGrid(_ options: [ASRLanguageOption]) -> some View {
        LazyVGrid(columns: languageColumns, alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                clientLanguageToggle(option)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func clientLanguageToggle(_ option: ASRLanguageOption) -> some View {
        Toggle(isOn: Binding(
            get: { selectedClientLanguageIDs.contains(option.id) },
            set: { setClientLanguage(option, enabled: $0) }
        )) {
            Text(option.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .toggleStyle(.checkbox)
        .disabled(selectedClientLanguageIDs.contains(option.id) && selectedClientLanguageIDs.count == 1)
    }

    private func setServerLanguage(_ option: ASRLanguageOption, enabled: Bool) {
        var selected = Set(selectedServerLanguageIDs)
        if enabled {
            selected.insert(option.id)
        } else if selected.count > 1 {
            selected.remove(option.id)
        }
        draft?.languageIDs = serverSupportedLanguageOptions.map(\.id).filter { selected.contains($0) }
        normalizeDraft()
    }

    private func setClientLanguage(_ option: ASRLanguageOption, enabled: Bool) {
        var selected = Set(selectedClientLanguageIDs)
        if enabled {
            selected.insert(option.id)
        } else if selected.count > 1 {
            selected.remove(option.id)
        }
        let ordered = clientSupportedLanguageOptions.map(\.id).filter { selected.contains($0) }
        clientLanguageIDsRaw = ASRLanguageSelection.rawValue(
            for: ordered,
            supportedOptions: clientSupportedLanguageOptions
        )
    }

    private func normalizeDraft() {
        guard var current = draft else { return }
        current.normalize()
        draft = current
    }

    @MainActor
    private func checkRoutes() async {
        isChecking = true
        statusMessage = ""
        statusIsError = false
        defer { isChecking = false }
        routeStatus = await ClientBridgeRouteResolver().resolve(
            config: clientConfig,
            probeAllEndpoints: true
        )
        if routeStatus.activeURL != nil {
            statusMessage = "\(routeStatus.activeKind.rawValue) active"
            statusIsError = false
        } else {
            statusMessage = "Bridge unavailable"
            statusIsError = true
        }
    }

    @MainActor
    private func loadSettings(force: Bool) async {
        guard force || draft == nil else { return }
        guard clientConfig.isConfigured else { return }
        isLoading = true
        statusMessage = ""
        statusIsError = false
        defer { isLoading = false }
        do {
            let resolved = try await RemoteBridgeClient.resolvedFromSettings(probeAllEndpoints: true)
            routeStatus = resolved.routeStatus
            var settings = try await resolved.client.settings()
            settings.normalize()
            draft = settings
            applyServerDefaults(settings)
            statusMessage = "Pulled from \(resolved.routeStatus.activeKind.rawValue)"
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }

    @MainActor
    private func saveSettings() async {
        guard var current = draft else { return }
        current.normalize()
        isSaving = true
        statusMessage = ""
        statusIsError = false
        defer { isSaving = false }
        do {
            let resolved = try await RemoteBridgeClient.resolvedFromSettings(probeAllEndpoints: true)
            routeStatus = resolved.routeStatus
            var updated = try await resolved.client.updateSettings(current)
            updated.normalize()
            draft = updated
            applyServerDefaults(updated)
            statusMessage = "Saved to \(resolved.routeStatus.activeKind.rawValue)"
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }

    private func applyServerDefaults(_ settings: BridgeSettingsPayload) {
        ClientBridgeSettingsSync.applyServerDefaults(settings)
        clientLanguageIDsRaw = UserDefaults.standard.string(forKey: AppSettings.Keys.clientLanguageIDs)
            ?? ASRLanguageSelection.defaultRawValue
    }

    private func endpointState(isConfigured: Bool, isChecked: Bool, isOK: Bool) -> String {
        if !isConfigured { return "Not configured" }
        if isOK { return "Available" }
        return isChecked ? "Unavailable" : "Not checked"
    }

    private func pastePairingJSON() {
        let raw = NSPasteboard.general.string(forType: .string) ?? ""
        guard let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            statusMessage = "Clipboard is empty"
            statusIsError = true
            return
        }
        do {
            let payload = try JSONDecoder().decode(BridgePairingPayload.self, from: data)
            let config = ClientBridgeConfiguration.fromPairingPayload(payload)
            clientLocalBridgeURLsRaw = ClientBridgeConfiguration.rawValue(for: config.localBridgeURLs)
            clientCloudBridgeURL = config.cloudBridgeURL
            clientBridgeToken = config.token
            statusMessage = "Pairing JSON applied"
            statusIsError = false
            Task {
                await checkRoutes()
                await loadSettings(force: true)
            }
        } catch {
            statusMessage = "Couldn't parse pairing JSON"
            statusIsError = true
        }
    }
}

private struct DisclosureRow: View {
    let title: String
    let count: Int
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Text("\(count)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct ClientRouteRow: View {
    let title: String
    let endpoint: String
    let state: String
    let latencyMs: Int?
    let isActive: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                    if isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(tint.opacity(0.16)))
                            .foregroundStyle(tint)
                    }
                }
                .font(.subheadline.weight(.medium))
                Text(endpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(state)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dotColor)
                if let latencyMs {
                    Text("\(latencyMs)ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var dotColor: Color {
        switch state {
        case "Available":
            return tint
        case "Unavailable":
            return .orange
        default:
            return .secondary
        }
    }
}

// MARK: - Recording

struct RecordingSettingsView: View {
    @AppStorage(AppSettings.Keys.maxRecordingDuration) private var maxDuration: Double = 30
    @AppStorage(AppSettings.Keys.alwaysShowHUD)        private var alwaysShowHUD: Bool = false
    @AppStorage(AppSettings.Keys.holdModifier)         private var holdModifierRaw: String = HoldModifier.rightOption.rawValue

    var body: some View {
        Form {
            Section("Hold to talk (double-tap)") {
                Picker("Hold modifier", selection: $holdModifierRaw) {
                    ForEach(HoldModifier.allCases) { m in
                        Text(m.displayName).tag(m.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("Double-tap the chosen key and HOLD on the second press to record. Release to stop. Matches macOS Dictation / Wispr Flow / SuperWhisper conventions. Set to Off to disable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Toggle (combo shortcut)") {
                HStack(spacing: 12) {
                    Text("Shortcut")
                        .frame(minWidth: 90, alignment: .leading)
                    KeyboardShortcuts.Recorder(for: .toggleDictation)
                    Spacer()
                    Button("Reset") { KeyboardShortcuts.reset(.toggleDictation) }
                }
                Text("Press once to start, press again to stop. While transcribing or correcting, press again to cancel. Combo (⌘ ⌥ ⌃ ⇧ + key) only — single modifiers belong in the hold section above. Default is ⌘⇧Space.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Command selected text") {
                HStack(spacing: 12) {
                    Text("Shortcut")
                        .frame(minWidth: 90, alignment: .leading)
                    KeyboardShortcuts.Recorder(for: .commandTextEdit)
                    Spacer()
                    Button("Reset") { KeyboardShortcuts.reset(.commandTextEdit) }
                }
                Text("Press once to speak an edit command for the current selection. If there is no selection, Typeforme uses the focused text field when Accessibility exposes it. Default is ⌘⌥Space.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("HUD") {
                Toggle("Always show HUD", isOn: $alwaysShowHUD)
                Text("Off (default): the capsule overlay only appears while you're dictating. On: it stays visible at the bottom even when idle, showing the current hotkey.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Duration") {
                HStack {
                    Slider(value: $maxDuration, in: 5...120, step: 5)
                    Text("\(Int(maxDuration))s").monospacedDigit().frame(width: 50, alignment: .trailing)
                }
                Text("Auto-stop after this many seconds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - ASR

private struct WhisperModelOption: Identifiable {
    let id: String
    let label: String
    let detail: String
}

private let whisperModelOptions: [WhisperModelOption] = [
    WhisperModelOption(
        id: "tiny",
        label: "Tiny",
        detail: "Fastest. Useful for debugging, weak for mixed or less common languages."
    ),
    WhisperModelOption(
        id: "base",
        label: "Base",
        detail: "Still fast, slightly better than Tiny."
    ),
    WhisperModelOption(
        id: "small_216MB",
        label: "Small (~216 MB)",
        detail: "Good middle ground for short dictation."
    ),
    WhisperModelOption(
        id: "medium",
        label: "Medium",
        detail: "Higher accuracy, slower and larger download."
    ),
    WhisperModelOption(
        id: "distil-large-v3_594MB",
        label: "Distil Large v3 (~594 MB)",
        detail: "Large-v3 family, smaller and usually faster."
    ),
    WhisperModelOption(
        id: "large-v3-v20240930_626MB",
        label: "Large v3 2024 (~626 MB)",
        detail: "Recommended for multilingual accuracy."
    ),
    WhisperModelOption(
        id: "large-v3-v20240930_turbo_632MB",
        label: "Large v3 2024 Turbo (~632 MB)",
        detail: "Faster large-v3 variant. Good for interactive use."
    ),
    WhisperModelOption(
        id: "large-v3_947MB",
        label: "Large v3 Full (~947 MB)",
        detail: "Bigger Core ML package; try when accuracy matters more than startup."
    ),
    WhisperModelOption(
        id: "large-v3_turbo_954MB",
        label: "Large v3 Turbo Full (~954 MB)",
        detail: "Bigger turbo package; faster than full large-v3 on supported Macs."
    ),
]

struct ASRSettingsView: View {
    @AppStorage(AppSettings.Keys.asrProvider)        private var provider: String = "qwen3-asr-llama"
    @AppStorage(AppSettings.Keys.asrModel)           private var model: String = "large-v3-v20240930_626MB"
    @AppStorage(AppSettings.Keys.asrLanguageIDs)     private var languageIDsRaw: String = ASRLanguageSelection.defaultRawValue
    @AppStorage(AppSettings.Keys.asrUnloadAfterMin)  private var unloadAfterMin: Int = 0
    @AppStorage(AppSettings.Keys.asrWhisperKitTimeoutSec) private var whisperTimeoutSec: Double = 120
    @AppStorage(AppSettings.Keys.asrQwenLlamaTimeoutSec) private var qwenTimeoutSec: Double = 120
    @AppStorage(AppSettings.Keys.asrQwenLlamaModelID) private var qwenModelID: String = QwenASRModelCatalog.defaultID
    @AppStorage(AppSettings.Keys.asrQwenLlamaMaxTokens) private var qwenMaxTokens: Int = 2048
    @State private var isPreparingModel = false
    @State private var preparationStatus = "Not checked"
    @State private var preparationDetail = ""
    @State private var preparationProgress: Double?
    @State private var preparationTask: Task<Void, Never>?
    @State private var showAllLanguages = false

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Provider", selection: $provider) {
                    Text("Qwen3-ASR (default)").tag("qwen3-asr-llama")
                    Text("WhisperKit").tag("whisperkit")
                }
                .pickerStyle(.menu)

                if isWhisperProvider {
                    Picker("Model", selection: $model) {
                        ForEach(whisperModelOptions) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    IntegerSettingField(
                        title: "Timeout",
                        value: Binding(
                            get: { Int(whisperTimeoutSec) },
                            set: { whisperTimeoutSec = Double($0) }
                        ),
                        range: 10...300,
                        suffix: "s"
                    )
                    Text(selectedWhisperModel?.detail ?? "WhisperKit downloads the chosen model from HuggingFace.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Use Download & Warm Up to avoid the first dictation doing download and Core ML specialization work.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: $qwenModelID) {
                        ForEach(QwenASRModelCatalog.all) { spec in
                            Text(spec.label).tag(spec.id)
                        }
                    }
                    .pickerStyle(.menu)
                    IntegerSettingField(
                        title: "Timeout",
                        value: Binding(
                            get: { Int(qwenTimeoutSec) },
                            set: { qwenTimeoutSec = Double($0) }
                        ),
                        range: 10...300,
                        suffix: "s"
                    )
                    IntegerSettingField(
                        title: "Max transcript tokens",
                        value: $qwenMaxTokens,
                        range: 128...8192,
                        suffix: "tokens"
                    )
                    Text(selectedQwenModel.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("This caps only Qwen-ASR transcript output. It is not the correction model token limit.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Languages") {
                Text(selectedLanguageSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                languageGrid(commonLanguageOptions)

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showAllLanguages.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showAllLanguages ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text("All languages")
                        Spacer()
                        Text("\(allOtherLanguages.count)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showAllLanguages {
                    languageGrid(allOtherLanguages)
                        .padding(.top, 2)
                }

                Text(languageHelpText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if isWhisperProvider {
                Section("WhisperKit model") {
                    whisperStatusRow
                    if isPreparingModel {
                        if let preparationProgress {
                            ProgressView(value: preparationProgress)
                        } else {
                            ProgressView()
                        }
                    }
                    HStack {
                        Button {
                            preparationTask?.cancel()
                            preparationTask = Task { await prepareSelectedModel() }
                        } label: {
                            Label("Download & Warm Up", systemImage: "arrow.down.circle")
                        }
                        .disabled(isPreparingModel)

                        Button {
                            revealWhisperKitCache()
                        } label: {
                            Label("Reveal Cache", systemImage: "folder")
                        }
                        Button(role: .destructive) {
                            deleteSelectedWhisperModel()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(isPreparingModel || ASRFactory.shared.whisperKitCachedModelInfo(modelName: model) == nil)
                    }
                }
                Section("Memory") {
                    IntegerSettingField(
                        title: "Unload after idle",
                        value: $unloadAfterMin,
                        range: 0...60,
                        suffix: "min"
                    )
                    Text("Frees the GPU once you stop dictating. Reloads on the next hotkey press.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Qwen3-ASR model") {
                    QwenASRModelRow(spec: selectedQwenModel)
                        .id(selectedQwenModel.id)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            normalizeProvider()
            clampLanguageSelection()
            resetPreparationStatus()
        }
        .onChange(of: model) { _, _ in
            preparationTask?.cancel()
            resetPreparationStatus()
        }
        .onChange(of: provider) { _, _ in
            normalizeProvider()
            clampLanguageSelection()
            preparationTask?.cancel()
            if isWhisperProvider {
                resetPreparationStatus()
            }
        }
        .onChange(of: qwenModelID) { _, _ in
            Task { @MainActor in await ASRFactory.shared.stopQwenLlama() }
        }
    }

    private var isWhisperProvider: Bool {
        provider.lowercased() == "whisperkit"
    }

    private var selectedLanguageIDs: [String] {
        ASRLanguageSelection.parse(languageIDsRaw, supportedOptions: supportedLanguageOptions)
    }

    private var selectedWhisperModel: WhisperModelOption? {
        whisperModelOptions.first { $0.id == model }
    }

    private var selectedQwenModel: QwenASRModelSpec {
        QwenASRModelCatalog.spec(for: qwenModelID)
    }

    private var selectedLanguageSummary: String {
        "Enabled: " + ASRLanguageSelection
            .displayNames(for: selectedLanguageIDs, supportedOptions: supportedLanguageOptions)
            .joined(separator: ", ")
    }

    private var languageHelpText: String {
        if isWhisperProvider {
            return "Select one language to pass Whisper a strong language hint. Select multiple languages for mixed speech: WhisperKit detects the language, and the correction prompt is constrained to the checked languages. WhisperKit does not currently expose an API to limit detection candidates to only these languages."
        }
        return "Qwen3-ASR through llama.cpp detects the language automatically across its supported languages. The checked languages constrain script normalization and correction after ASR."
    }

    private var allOtherLanguages: [ASRLanguageOption] {
        supportedLanguageOptions.filter { !$0.isCommon }
    }

    private var supportedLanguageOptions: [ASRLanguageOption] {
        ASRLanguageSelection.supportedOptions(forProvider: provider)
    }

    private var commonLanguageOptions: [ASRLanguageOption] {
        ASRLanguageSelection.commonOptions(forProvider: provider)
    }

    private var languageColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 168), spacing: 10, alignment: .leading)]
    }

    private func languageGrid(_ options: [ASRLanguageOption]) -> some View {
        LazyVGrid(columns: languageColumns, alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                languageToggle(option)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func languageToggle(_ option: ASRLanguageOption) -> some View {
        let selected = selectedLanguageIDs.contains(option.id)
        Toggle(isOn: Binding(
            get: { selectedLanguageIDs.contains(option.id) },
            set: { setLanguage(option, enabled: $0) }
        )) {
            Text(option.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .toggleStyle(.checkbox)
        .disabled(selected && selectedLanguageIDs.count == 1)
    }

    private func setLanguage(_ option: ASRLanguageOption, enabled: Bool) {
        var selected = Set(selectedLanguageIDs)
        if enabled {
            selected.insert(option.id)
        } else if selected.count > 1 {
            selected.remove(option.id)
        }
        let ordered = supportedLanguageOptions.map(\.id).filter { selected.contains($0) }
        languageIDsRaw = ASRLanguageSelection.rawValue(for: ordered, supportedOptions: supportedLanguageOptions)
    }

    private var preparationColor: Color {
        if isPreparingModel { return .orange }
        if preparationStatus == "Downloaded" || preparationStatus == "Ready" { return .green }
        if preparationStatus == "Failed" { return .red }
        return .secondary
    }

    @ViewBuilder
    private var whisperStatusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(preparationColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(preparationStatus)
                Text(preparationDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private func resetPreparationStatus() {
        isPreparingModel = false
        preparationProgress = nil
        if let cached = ASRFactory.shared.whisperKitCachedModelInfo(modelName: model) {
            preparationStatus = "Downloaded"
            preparationDetail = cached.usesDocumentDirectoryCache ? "Document cache: \(cached.modelFolder.path)" : cached.modelFolder.path
        } else {
            preparationStatus = "Not Downloaded"
            preparationDetail = "Cache: \(ASRFactory.shared.whisperKitCacheDir.path)"
        }
    }

    @MainActor
    private func prepareSelectedModel() async {
        let selectedModel = model
        isPreparingModel = true
        preparationProgress = nil
        preparationStatus = "Connecting"
        preparationDetail = selectedModel

        do {
            let folder = try await ASRFactory.shared.prepareWhisperKitModel(
                modelName: selectedModel,
                progress: { update in
                    guard selectedModel == model else { return }
                    preparationProgress = update.isByteProgress ? update.fractionCompleted.map { min(max($0, 0), 1) } : nil
                    if let fraction = preparationProgress, update.isByteProgress {
                        preparationStatus = "Downloading \(Int((fraction * 100).rounded()))%"
                    } else {
                        preparationStatus = "Downloading"
                    }
                    preparationDetail = progressDetail(update)
                },
                stage: { stage in
                    guard selectedModel == model else { return }
                    switch stage {
                    case .downloading:
                        preparationStatus = "Downloading"
                        preparationDetail = "Fetching model files from HuggingFace..."
                    case .loading:
                        preparationProgress = nil
                        preparationStatus = "Loading"
                        preparationDetail = "Loading cached model..."
                    case .warmingUp:
                        preparationProgress = nil
                        preparationStatus = "Warming Up"
                        preparationDetail = "Specializing Core ML models for this Mac..."
                    case .ready:
                        preparationProgress = nil
                        preparationStatus = "Ready"
                    }
                }
            )
            guard !Task.isCancelled else { return }
            preparationProgress = nil
            preparationStatus = "Ready"
            preparationDetail = folder.path
        } catch is CancellationError {
            preparationStatus = "Cancelled"
            preparationDetail = "Cache: \(ASRFactory.shared.whisperKitCacheDir.path)"
        } catch {
            preparationStatus = "Failed"
            preparationDetail = error.localizedDescription
        }

        isPreparingModel = false
    }

    private func progressDetail(_ update: WhisperKitPreparationProgress) -> String {
        guard update.isByteProgress, update.totalUnitCount > 0 else {
            if update.totalUnitCount > 0 {
                return "Downloading model files... (\(update.completedUnitCount)/\(update.totalUnitCount))"
            }
            return "Downloading model files..."
        }
        let done = ByteCountFormatter.string(fromByteCount: update.completedUnitCount, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: update.totalUnitCount, countStyle: .file)
        return "\(done) / \(total)"
    }

    private func revealWhisperKitCache() {
        try? AppPaths.ensureDirectories()
        NSWorkspace.shared.activateFileViewerSelecting([ASRFactory.shared.whisperKitCacheDir])
    }

    private func deleteSelectedWhisperModel() {
        do {
            preparationTask?.cancel()
            try ASRFactory.shared.deleteWhisperKitModel(modelName: model)
            resetPreparationStatus()
        } catch {
            preparationStatus = "Failed"
            preparationDetail = error.localizedDescription
        }
    }

    private func normalizeProvider() {
        let value = provider.lowercased()
        let normalizedQwenModelID = QwenASRModelCatalog.spec(for: qwenModelID).id
        if qwenModelID != normalizedQwenModelID {
            qwenModelID = normalizedQwenModelID
        }
        if value != "whisperkit" && value != "qwen3-asr-llama" {
            provider = "qwen3-asr-llama"
        }
    }

    private func clampLanguageSelection() {
        let normalized = ASRLanguageSelection.rawValue(
            for: selectedLanguageIDs,
            supportedOptions: supportedLanguageOptions
        )
        if languageIDsRaw != normalized {
            languageIDsRaw = normalized
        }
    }
}

private struct QwenASRModelRow: View {
    let spec: QwenASRModelSpec

    @AppStorage private var modelPath: String
    @AppStorage private var mmprojPath: String
    @AppStorage private var modelURL: String
    @AppStorage private var mmprojURL: String
    @StateObject private var modelDownloader = ModelDownloader()
    @StateObject private var mmprojDownloader = ModelDownloader()
    @State private var deleteError: String?

    init(spec: QwenASRModelSpec) {
        self.spec = spec
        self._modelPath = AppStorage(wrappedValue: spec.defaultModelPath, spec.modelPathKey)
        self._mmprojPath = AppStorage(wrappedValue: spec.defaultMMProjPath, spec.mmprojPathKey)
        self._modelURL = AppStorage(wrappedValue: spec.defaultModelURL, spec.modelURLKey)
        self._mmprojURL = AppStorage(wrappedValue: spec.defaultMMProjURL, spec.mmprojURLKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.label).bold()
                    Text(spec.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                combinedStatusLabel
            }
            HStack {
                Text("Model").frame(width: 60, alignment: .leading)
                TextField("", text: $modelPath).textFieldStyle(.roundedBorder)
                Button("Reveal") { reveal(modelPath) }
            }
            HStack {
                Text("URL").frame(width: 60, alignment: .leading)
                TextField("", text: $modelURL).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("mmproj").frame(width: 60, alignment: .leading)
                TextField("", text: $mmprojPath).textFieldStyle(.roundedBorder)
                Button("Reveal") { reveal(mmprojPath) }
            }
            HStack {
                Text("URL").frame(width: 60, alignment: .leading)
                TextField("", text: $mmprojURL).textFieldStyle(.roundedBorder)
            }
            downloadControls
        }
        .padding(.vertical, 4)
    }

    private var combinedStatusLabel: some View {
        let installed = modelExists && mmprojExists
        return Text(installed ? "Installed" : "\(modelExists ? 1 : 0)/2 files")
            .font(.caption)
            .foregroundStyle(installed ? .green : .secondary)
    }

    @ViewBuilder
    private var downloadControls: some View {
        if isDownloading {
            VStack(alignment: .leading, spacing: 4) {
                if case .downloading(let received, let total) = modelDownloader.state {
                    downloadProgress(title: "Model", received: received, total: total)
                }
                if case .downloading(let received, let total) = mmprojDownloader.state {
                    downloadProgress(title: "mmproj", received: received, total: total)
                }
                Button {
                    modelDownloader.cancel()
                    mmprojDownloader.cancel()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            }
        } else {
            HStack {
                Button {
                    startDownloads()
                } label: {
                    Label(modelExists && mmprojExists ? "Update" : "Download", systemImage: "arrow.down.circle")
                }
                .disabled(modelURL.trimmingCharacters(in: .whitespaces).isEmpty || mmprojURL.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(role: .destructive) {
                    deleteModel()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!modelExists && !mmprojExists)
                if let why = failureText {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if let deleteError {
                    Text(deleteError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if completedBothDownloads {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
            }
        }
    }

    private func downloadProgress(title: String, received: Int64, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: total > 0 ? Double(received) / Double(total) : 0)
            HStack {
                Text("\(title): \(format(received)) / \(format(total))")
                    .font(.caption)
                    .monospacedDigit()
                Spacer()
            }
        }
    }

    private func startDownloads() {
        let modelURLString = modelURL.trimmingCharacters(in: .whitespaces)
        let mmprojURLString = mmprojURL.trimmingCharacters(in: .whitespaces)
        guard let modelDownloadURL = URL(string: modelURLString),
              let mmprojDownloadURL = URL(string: mmprojURLString)
        else { return }
        deleteError = nil
        Task { @MainActor in
            try? AppPaths.ensureDirectories()
            await ASRFactory.shared.stopQwenLlama()
            modelDownloader.start(from: modelDownloadURL, to: URL(fileURLWithPath: effectiveModelPath))
            mmprojDownloader.start(from: mmprojDownloadURL, to: URL(fileURLWithPath: effectiveMMProjPath))
        }
    }

    private func deleteModel() {
        let targets = [URL(fileURLWithPath: effectiveModelPath), URL(fileURLWithPath: effectiveMMProjPath)]
        deleteError = nil
        Task { @MainActor in
            await ASRFactory.shared.stopQwenLlama()
            do {
                for target in targets where FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                modelDownloader.reset()
                mmprojDownloader.reset()
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func reveal(_ path: String) {
        let effectivePath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = URL(fileURLWithPath: effectivePath.isEmpty ? spec.defaultModelPath : effectivePath)
        let dir = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    private func format(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private var effectiveModelPath: String {
        modelPath.isEmpty ? spec.defaultModelPath : modelPath
    }

    private var effectiveMMProjPath: String {
        mmprojPath.isEmpty ? spec.defaultMMProjPath : mmprojPath
    }

    private var modelExists: Bool {
        FileManager.default.fileExists(atPath: effectiveModelPath)
    }

    private var mmprojExists: Bool {
        FileManager.default.fileExists(atPath: effectiveMMProjPath)
    }

    private var isDownloading: Bool {
        if case .downloading = modelDownloader.state { return true }
        if case .downloading = mmprojDownloader.state { return true }
        return false
    }

    private var completedBothDownloads: Bool {
        if case .completed = modelDownloader.state,
           case .completed = mmprojDownloader.state {
            return true
        }
        return false
    }

    private var failureText: String? {
        if case .failed(let why) = modelDownloader.state { return "Model: \(why)" }
        if case .failed(let why) = mmprojDownloader.state { return "mmproj: \(why)" }
        return nil
    }
}

// MARK: - Correction

struct CorrectionSettingsView: View {
    @AppStorage(AppSettings.Keys.correctionBackend)       private var backendRaw: String = CorrectionBackendKind.qwen35_2B.rawValue
    @AppStorage(AppSettings.Keys.correctionTimeoutMs)     private var timeoutMs: Int = 1500
    @AppStorage(AppSettings.Keys.correctionColdTimeoutMs) private var coldTimeoutMs: Int = 8000
    @AppStorage(AppSettings.Keys.correctionMaxTokens)     private var maxTokens: Int = 128
    @AppStorage(AppSettings.Keys.correctionContextSize)   private var contextSize: Int = 4096
    @AppStorage(AppSettings.Keys.correctionMode)   private var correctionModeRaw: String = CorrectionMode.polish.rawValue
    @AppStorage(AppSettings.Keys.correctionAutoCommit)    private var autoCommit: Bool = true
    @AppStorage(AppSettings.Keys.numberOutputPreference)  private var numberOutputPreferenceRaw: String = NumberOutputPreference.automatic.rawValue
    @AppStorage(AppSettings.Keys.punctuationPreference)   private var punctuationPreferenceRaw: String = PunctuationOutputPreference.normal.rawValue
    @AppStorage(AppSettings.Keys.lmStudioBaseURL)         private var lmStudioBaseURL: String = "http://127.0.0.1:1234/v1"
    @AppStorage(AppSettings.Keys.lmStudioAPIKey)          private var lmStudioAPIKey: String = ""
    @AppStorage(AppSettings.Keys.lmStudioModel)           private var lmStudioModel: String = ""
    @State private var showAdvanced = false
    @State private var modelLoadStatus: String?
    @State private var modelLoadIsError = false
    @State private var loadingBackendRaw: String?
    @State private var isCheckingLMStudio = false
    @State private var lmStudioStatus = "Not checked"
    @State private var lmStudioDetail = "Start LM Studio's OpenAI-compatible server, then check the connection."
    @State private var lmStudioModels: [String] = []

    private let selectableBackends: [CorrectionBackendKind] = [
        .qwen35_2B,
        .qwen35_4B,
        .qwen35_9B,
        .externalLMStudio,
    ]

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Correction engine", selection: $backendRaw) {
                    ForEach(selectableBackends, id: \.rawValue) { kind in
                        Text(backendLabel(kind)).tag(kind.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Picker("Mode", selection: $correctionModeRaw) {
                    ForEach(CorrectionMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text(correctionModeDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("Numbers", selection: $numberOutputPreferenceRaw) {
                    ForEach(NumberOutputPreference.allCases) { preference in
                        Text(preference.displayName).tag(preference.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text(numberOutputPreferenceDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("Punctuation", selection: $punctuationPreferenceRaw) {
                    ForEach(PunctuationOutputPreference.allCases) { preference in
                        Text(preference.displayName).tag(preference.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text(punctuationPreferenceDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("Auto-commit (skip preview)", isOn: $autoCommit)

                Text("Pick an explicit engine so latency and quality tests are honest.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let modelLoadStatus {
                    HStack(spacing: 6) {
                        if loadingBackendRaw != nil {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(modelLoadStatus)
                            .font(.caption)
                            .foregroundStyle(modelLoadIsError ? .red : .secondary)
                    }
                }
            }
            if backendRaw == CorrectionBackendKind.externalLMStudio.rawValue {
                Section("LM Studio experiment") {
                    TextField("Base URL", text: $lmStudioBaseURL)
                        .textFieldStyle(.roundedBorder)
                    if lmStudioPickerModels.isEmpty {
                        TextField("Model ID", text: $lmStudioModel)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Model", selection: $lmStudioModel) {
                            if lmStudioModel.isEmpty {
                                Text("Select a model").tag("")
                            }
                            ForEach(lmStudioPickerModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    SecureField("API key (optional)", text: $lmStudioAPIKey)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 10) {
                        Circle()
                            .fill(lmStudioColor)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lmStudioStatus)
                            Text(lmStudioDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }

                    HStack {
                        Button {
                            Task { await checkLMStudio(selectFirstModel: lmStudioModel.isEmpty) }
                        } label: {
                            Label(isCheckingLMStudio ? "Checking" : "Refresh Models", systemImage: "arrow.clockwise")
                        }
                        .disabled(isCheckingLMStudio)
                    }

                    Text("Uses any reachable LM Studio OpenAI-compatible /v1 server, including LAN URLs. Qwen models receive no-think chat hints so content is returned as JSON instead of hidden reasoning.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Local LLM models (Qwen3.5 via llama.cpp)") {
                ForEach(localLlamaModels) { spec in
                    ModelDownloadRow(
                        spec: spec,
                        isSelected: backendRaw == spec.backendKind.rawValue
                    )
                    if spec.id != (localLlamaModels.last?.id ?? "") {
                        Divider()
                    }
                }
            }
            Section("Advanced") {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showAdvanced.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text("Timing and generation limits")
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showAdvanced {
                    IntegerSettingField(title: "Normal timeout", value: $timeoutMs, range: 200...30000, suffix: "ms")
                    if let timeoutHint = effectiveTimeoutHint {
                        Text(timeoutHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    IntegerSettingField(title: "Model startup timeout", value: $coldTimeoutMs, range: 1000...30000, suffix: "ms")
                    IntegerSettingField(title: "Max output tokens", value: $maxTokens, range: 32...512, suffix: "tokens")
                    IntegerSettingField(title: "Context size", value: $contextSize, range: 1024...8192, suffix: "tokens")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            normalizeBackendSelection()
            if backendRaw == CorrectionBackendKind.externalLMStudio.rawValue {
                Task { await checkLMStudio(selectFirstModel: lmStudioModel.isEmpty) }
            }
        }
        .onChange(of: backendRaw) { _, _ in
            normalizeBackendSelection()
            preloadSelectedBackend()
        }
        .onChange(of: lmStudioBaseURL) { _, _ in
            lmStudioModels = []
            lmStudioStatus = "Not checked"
            lmStudioDetail = "Refresh models after changing the server URL."
        }
        .onChange(of: lmStudioAPIKey) { _, _ in
            lmStudioModels = []
            lmStudioStatus = "Not checked"
            lmStudioDetail = "Refresh models after changing the API key."
        }
    }

    private func backendLabel(_ kind: CorrectionBackendKind) -> String {
        switch kind {
        case .qwen35_2B: return "Qwen3.5 2B (good)"
        case .qwen35_4B: return "Qwen3.5 4B (better)"
        case .qwen35_9B: return "Qwen3.5 9B (best)"
        case .externalLMStudio: return "LM Studio (experimental)"
        }
    }

    private var correctionModeDescription: String {
        (CorrectionMode(rawValue: correctionModeRaw) ?? .polish).helpText
    }

    private var numberOutputPreferenceDescription: String {
        NumberOutputPreference.normalized(numberOutputPreferenceRaw).helpText
    }

    private var punctuationPreferenceDescription: String {
        PunctuationOutputPreference.normalized(punctuationPreferenceRaw).helpText
    }

    private var effectiveTimeoutHint: String? {
        if backendRaw == CorrectionBackendKind.externalLMStudio.rawValue,
           timeoutMs < LMStudioCorrectorService.minimumRequestTimeoutMs {
            return "LM Studio requests use at least \(LMStudioCorrectorService.minimumRequestTimeoutMs) ms so large local models can finish."
        }
        return nil
    }

    private func normalizeBackendSelection() {
        guard let kind = CorrectionBackendKind(rawValue: backendRaw),
              selectableBackends.contains(kind) else {
            backendRaw = CorrectionBackendKind.qwen35_2B.rawValue
            return
        }
    }

    private func preloadSelectedBackend() {
        guard let kind = CorrectionBackendKind(rawValue: backendRaw) else { return }
        let raw = backendRaw
        loadingBackendRaw = raw
        modelLoadIsError = false
        modelLoadStatus = "Loading \(backendLabel(kind))..."
        Task { @MainActor in
            await CorrectorFactory.shared.shutdownAll()
            if kind == .externalLMStudio {
                let report = await LMStudioCorrectorService.checkConfiguration()
                guard backendRaw == raw else { return }
                loadingBackendRaw = nil
                applyLMStudioReport(report, selectFirstModel: lmStudioModel.isEmpty)
                modelLoadIsError = !report.ok
                modelLoadStatus = report.ok ? "LM Studio is reachable." : "LM Studio is not reachable."
                return
            }
            if let path = localModelPath(for: kind),
               !FileManager.default.fileExists(atPath: path) {
                guard backendRaw == raw else { return }
                loadingBackendRaw = nil
                modelLoadIsError = true
                modelLoadStatus = "Download \(backendLabel(kind)) before using it."
                return
            }
            let result = await CorrectorFactory.shared.preloadActiveModels()
            guard backendRaw == raw else { return }
            loadingBackendRaw = nil
            modelLoadIsError = !result.isReady
            modelLoadStatus = result.isReady
                ? result.message
                : "Load failed for \(backendLabel(kind)): \(result.message)"
        }
    }

    private func localModelPath(for kind: CorrectionBackendKind) -> String? {
        switch kind {
        case .qwen35_2B: return AppSettings.llama2BPath
        case .qwen35_4B: return AppSettings.llama4BPath
        case .qwen35_9B: return AppSettings.llama9BPath
        default: return nil
        }
    }

    private var lmStudioColor: Color {
        if isCheckingLMStudio { return .orange }
        if lmStudioStatus == "Ready" { return .green }
        if lmStudioStatus == "Failed" { return .red }
        return .secondary
    }

    private var lmStudioPickerModels: [String] {
        var models = lmStudioModels
        if !lmStudioModel.isEmpty && !models.contains(lmStudioModel) {
            models.insert(lmStudioModel, at: 0)
        }
        return models
    }

    @MainActor
    private func checkLMStudio(selectFirstModel: Bool) async {
        isCheckingLMStudio = true
        lmStudioStatus = "Checking"
        lmStudioDetail = lmStudioBaseURL
        let report = await LMStudioCorrectorService.checkConfiguration()
        isCheckingLMStudio = false
        applyLMStudioReport(report, selectFirstModel: selectFirstModel)
        modelLoadStatus = report.ok ? "LM Studio is reachable." : "LM Studio is not reachable."
    }

    private func applyLMStudioReport(_ report: LMStudioCheckReport, selectFirstModel: Bool) {
        lmStudioStatus = report.status
        lmStudioDetail = report.detail
        lmStudioModels = report.modelIDs
        if report.ok {
            let refreshedModel = LMStudioCorrectorService.modelSelectionAfterRefresh(
                current: lmStudioModel,
                available: report.modelIDs,
                selectFirstModel: selectFirstModel
            )
            if refreshedModel != lmStudioModel {
                lmStudioModel = refreshedModel
            }
        }
    }
}

/// One row for an embedded llama model: shows current path, file status,
/// and a download button driven by ModelDownloader. The Reveal button opens
/// the model folder in Finder so the user can manually drop a .gguf there too.
private struct ModelDownloadRow: View {
    let spec: LocalLlamaModelSpec
    let isSelected: Bool

    @AppStorage private var path: String
    @AppStorage private var url:  String
    @StateObject private var downloader = ModelDownloader()
    @State private var deleteError: String?

    init(spec: LocalLlamaModelSpec, isSelected: Bool) {
        self.spec = spec
        self.isSelected = isSelected
        self._path = AppStorage(wrappedValue: spec.defaultPath, spec.pathKey)
        self._url  = AppStorage(wrappedValue: "", spec.urlKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(spec.label).bold()
                        if isSelected {
                            Text("Selected")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.12), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                    }
                    Text(spec.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusLabel
            }
            HStack {
                Text("Path").frame(width: 60, alignment: .leading)
                TextField("", text: $path).textFieldStyle(.roundedBorder)
                Button("Reveal") { reveal() }
            }
            HStack {
                Text("URL").frame(width: 60, alignment: .leading)
                TextField("", text: $url).textFieldStyle(.roundedBorder)
            }
            downloadControls
        }
        .padding(.vertical, 4)
    }

    // MARK: - Sub-views

    private var statusLabel: some View {
        let exists = FileManager.default.fileExists(atPath: effectivePath)
        let size: Int64 = (try? FileManager.default.attributesOfItem(atPath: effectivePath)[.size] as? Int64) ?? 0
        return Text(exists ? "Installed (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))"
                           : "Not installed")
            .font(.caption)
            .foregroundStyle(exists ? .green : .secondary)
    }

    @ViewBuilder
    private var downloadControls: some View {
        switch downloader.state {
        case .idle, .completed, .failed:
            HStack {
                Button {
                    startDownload()
                } label: {
                    Label(
                        modelExists ? "Re-download" : "Download",
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(role: .destructive) {
                    deleteModel()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!modelExists || isDownloading)
                if case .failed(let why) = downloader.state {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if let deleteError {
                    Text(deleteError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if case .completed = downloader.state {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
            }
        case .downloading(let received, let total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: total > 0 ? Double(received) / Double(total) : 0)
                HStack {
                    Text("\(format(received)) / \(format(total))")
                        .font(.caption)
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel") { downloader.cancel() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Actions

    private func startDownload() {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard let u = URL(string: trimmed) else { return }
        let dest = URL(fileURLWithPath: effectivePath)
        deleteError = nil
        Task { @MainActor in
            try? AppPaths.ensureDirectories()
            await CorrectorFactory.shared.shutdownAll()
            downloader.start(from: u, to: dest)
        }
    }

    private func deleteModel() {
        let target = URL(fileURLWithPath: effectivePath)
        deleteError = nil
        Task { @MainActor in
            await CorrectorFactory.shared.shutdownAll()
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                downloader.reset()
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func reveal() {
        let dir = URL(fileURLWithPath: effectivePath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = URL(fileURLWithPath: effectivePath)
        if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    private func format(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private var effectivePath: String {
        path.isEmpty ? spec.defaultPath : path
    }

    private var modelExists: Bool {
        FileManager.default.fileExists(atPath: effectivePath)
    }

    private var isDownloading: Bool {
        if case .downloading = downloader.state { return true }
        return false
    }
}

// MARK: - Prompts

/// In-app editor for the base system prompt and per-mode addendum.
struct PromptsSettingsView: View {
    @AppStorage(AppSettings.Keys.promptAdditionalSystem) private var additionalSystemPrompt: String = ""
    @State private var correctionMode: CorrectionMode = .polish
    @State private var systemPromptText: String = ""
    @State private var originalSystemPromptText: String = ""
    @State private var systemHasOverride: Bool = false
    @State private var modePromptText: String = ""
    @State private var originalModePromptText: String = ""
    @State private var modePromptHasOverride: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                promptHeader(
                    title: "System prompt",
                    hasOverride: systemHasOverride,
                    reset: resetSystemOverride
                )

                promptEditor(text: $systemPromptText, minHeight: 160)

                HStack(alignment: .top) {
                    Text("Global correction contract. This file is shared by all correction modes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { saveSystemOverride() }
                        .keyboardShortcut("s")
                        .disabled(systemPromptText == originalSystemPromptText || trimmed(systemPromptText).isEmpty)
                }

                Divider()

                Picker("Mode", selection: $correctionMode) {
                    ForEach(CorrectionMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                promptHeader(
                    title: "Mode prompt",
                    hasOverride: modePromptHasOverride,
                    reset: resetModeOverride
                )

                promptEditor(text: $modePromptText, minHeight: 110)

                HStack(alignment: .top) {
                    Text("Only the selected mode behavior. Save writes \(PromptOverrideStore.modePromptFile(for: correctionMode).lastPathComponent).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { saveModeOverride() }
                        .disabled(modePromptText == originalModePromptText || trimmed(modePromptText).isEmpty)
                }

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "text.badge.plus")
                        .foregroundStyle(trimmed(additionalSystemPrompt).isEmpty ? Color.secondary : Color.accentColor)
                    Text("User prompt")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { additionalSystemPrompt = "" }
                        .controlSize(.small)
                        .disabled(trimmed(additionalSystemPrompt).isEmpty)
                }
                .font(.callout)

                promptEditor(text: $additionalSystemPrompt, minHeight: 86)
                    .frame(maxHeight: 120)

                Text("Personal preferences appended after system and mode prompts for every correction request.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .onAppear {
            loadSystemPrompt()
            loadModePrompt()
        }
        .onChange(of: correctionMode) { _, _ in loadModePrompt() }
    }

    private func promptHeader(title: String, hasOverride: Bool, reset: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: hasOverride ? "pencil.circle.fill" : "doc.circle")
                .foregroundStyle(hasOverride ? Color.accentColor : Color.secondary)
            Text(title)
            Text(hasOverride ? "Custom override" : "Built-in default")
                .foregroundStyle(.secondary)
            Spacer()
            if hasOverride {
                Button("Reset to default") { reset() }
                    .controlSize(.small)
            }
        }
        .font(.callout)
    }

    private func promptEditor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(.callout, design: .monospaced))
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(minHeight: minHeight)
    }

    private func loadSystemPrompt() {
        try? AppPaths.ensureDirectories()
        if let override = PromptOverrideStore.readSystemPrompt() {
            systemPromptText = override
            systemHasOverride = true
        } else {
            systemPromptText = BuiltInPrompts.baseSystem
            systemHasOverride = false
        }
        originalSystemPromptText = systemPromptText
    }

    private func loadModePrompt() {
        try? AppPaths.ensureDirectories()
        if let override = PromptOverrideStore.readModePrompt(for: correctionMode) {
            modePromptText = override
            modePromptHasOverride = true
        } else {
            modePromptText = BuiltInPrompts.modePrompt(correctionMode)
            modePromptHasOverride = false
        }
        originalModePromptText = modePromptText
    }

    private func saveSystemOverride() {
        try? AppPaths.ensureDirectories()
        let file = PromptOverrideStore.systemFile()
        do {
            try systemPromptText.write(to: file, atomically: true, encoding: .utf8)
            systemHasOverride = true
            originalSystemPromptText = systemPromptText
        } catch {
            Log.store.error("prompt override save failed: \(error.localizedDescription)")
        }
    }

    private func saveModeOverride() {
        try? AppPaths.ensureDirectories()
        let file = PromptOverrideStore.modePromptFile(for: correctionMode)
        do {
            try modePromptText.write(to: file, atomically: true, encoding: .utf8)
            modePromptHasOverride = true
            originalModePromptText = modePromptText
        } catch {
            Log.store.error("prompt override save failed: \(error.localizedDescription)")
        }
    }

    private func resetSystemOverride() {
        try? FileManager.default.removeItem(at: PromptOverrideStore.systemFile())
        loadSystemPrompt()
    }

    private func resetModeOverride() {
        try? FileManager.default.removeItem(at: PromptOverrideStore.modePromptFile(for: correctionMode))
        loadModePrompt()
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Vocabulary

struct DictionarySettingsView: View {
    @ObservedObject var store: UserDictionaryStore
    @State private var selectedType = "person"
    @State private var customType = ""
    @State private var surface = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Picker("Type", selection: $selectedType) {
                        ForEach(DictionaryEntry.suggestedTypes, id: \.self) { type in
                            Text(type.replacingOccurrences(of: "_", with: " ")).tag(type)
                        }
                        Text("custom").tag("custom")
                    }
                    .frame(width: 180)

                    if selectedType == "custom" {
                        TextField("Custom type", text: $customType)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                    }

                    TextField("Term, e.g. Ada Lovelace, AcmeDB, GraphRAG", text: $surface)
                        .textFieldStyle(.roundedBorder)

                    Button("Add") {
                        store.add(
                            type: resolvedType,
                            surface: surface
                        )
                        clearForm()
                    }
                    .disabled(surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              (selectedType == "custom" && customType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }

            List {
                ForEach(store.entries) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Text(entry.displayType)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Text(entry.surface)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(role: .destructive) {
                            store.remove(entry)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                .onDelete { store.remove(at: $0) }
            }
            .listStyle(.inset)
        }
        .padding()
    }

    private var resolvedType: String {
        selectedType == "custom" ? customType : selectedType
    }

    private func clearForm() {
        surface = ""
    }
}

// MARK: - Bridge

struct BridgeSettingsView: View {
    @AppStorage(AppSettings.Keys.bridgeEnabled) private var enabled = false
    @AppStorage(AppSettings.Keys.bridgeLANEnabled) private var lanEnabled = false
    @AppStorage(AppSettings.Keys.bridgeLANAdapter) private var lanAdapter = BridgePairingPayload.allLANAdaptersID
    @AppStorage(AppSettings.Keys.bridgePublicEnabled) private var publicEnabled = false
    @AppStorage(AppSettings.Keys.bridgePort) private var port = 18081
    @AppStorage(AppSettings.Keys.bridgeHostname) private var hostname = ""
    @State private var authToken = ""
    @State private var showToken = false
    @State private var copiedMessage = ""

    var body: some View {
        Form {
            Section("Bridge server") {
                Toggle("Enable Bridge", isOn: $enabled)
                HStack {
                    Text("Status")
                    Spacer()
                    Text(enabled ? "Enabled" : "Off")
                        .foregroundStyle(enabled ? .green : .secondary)
                }
                IntegerSettingField(title: "Port", value: $port, range: 1024...65535, suffix: "")
                Toggle("Allow LAN access", isOn: $lanEnabled)
                Picker("LAN adapter", selection: $lanAdapter) {
                    Text("All adapters").tag(BridgePairingPayload.allLANAdaptersID)
                    ForEach(availableLANAdapters) { adapter in
                        Text(adapter.displayName).tag(adapter.id)
                    }
                    if selectedAdapterMissing {
                        Text("Unavailable (\(lanAdapter))").tag(lanAdapter)
                    }
                }
                .disabled(!lanEnabled)
                HStack {
                    Text("Listening URL")
                    Spacer()
                    Text(verbatim: displayedBridgeURL)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("Bridge accepts requests from Typeforme clients and returns corrected text. It listens on 127.0.0.1 unless LAN access is enabled. The adapter setting controls which LAN URLs are included in pairing JSON.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Pair Clients") {
                HStack {
                    Text("Token")
                    Spacer()
                    Text(showToken ? currentToken : maskedToken)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        showToken.toggle()
                    } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showToken ? "Hide token" : "Show token")
                }
                HStack {
                    Button {
                        copyPairingJSON()
                    } label: {
                        Label("Copy Pairing JSON", systemImage: "doc.on.doc")
                    }
                    Button {
                        copyToken()
                    } label: {
                        Label("Copy Token", systemImage: "key")
                    }
                    Button(role: .destructive) {
                        authToken = AppSettings.rotateBridgeAuthToken()
                        showToken = false
                        copiedMessage = "Token rotated"
                    } label: {
                        Label("Rotate Token", systemImage: "arrow.clockwise")
                    }
                    Spacer()
                    if !copiedMessage.isEmpty {
                        Text(copiedMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Mac stores this token in local app settings to avoid Keychain permission prompts during local development builds. Other clients cannot read it automatically, so pair by copying the token or JSON into the client. Pairing JSON contains the token plus enabled client URLs: lan_bridge_url and lan_bridge_urls when LAN access is on, and public_bridge_url when Public Bridge URL is on. Clients pull languages and defaults from the server settings endpoint.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Public Bridge URL") {
                Toggle("Enable Public Bridge URL", isOn: $publicEnabled)
                TextField("Public bridge URL", text: $hostname, prompt: Text("https://voice.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!publicEnabled)
                Text("Optional. Use this when clients reach Bridge through a public URL. Cloudflare Tunnel, SSH tunnel, VPN, reverse proxy, or port forwarding are deployment choices outside Typeforme; configure them separately, then paste the client-facing URL here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Endpoints") {
                Text("GET  /v1/health\nGET  /v1/pairing\nGET  /v1/settings\nPOST /v1/settings\nPOST /v1/dictate\nPOST /v1/restyle\nPOST /v1/edit-text")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("All endpoints require the bearer token. Missing or wrong tokens return an empty not-found response. /v1/pairing returns token plus enabled LAN/public URLs for first setup; clients pull languages and defaults from /v1/settings. /v1/dictate uses multipart audio file upload and returns corrected text. /v1/restyle reuses text from a recent session or submitted text so mode switching does not require another recording. /v1/edit-text edits a selected or targeted text span from a spoken repair or command.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            authToken = AppSettings.ensureBridgeAuthToken()
        }
    }

    private var portString: String {
        String(port)
    }

    private var availableLANAdapters: [BridgeLANAdapter] {
        BridgePairingPayload.availableLANAdapters()
    }

    private var selectedAdapterMissing: Bool {
        lanAdapter != BridgePairingPayload.allLANAdaptersID
            && !availableLANAdapters.contains(where: { $0.id == lanAdapter })
    }

    private var displayedBridgeURL: String {
        if lanEnabled {
            let urls = BridgePairingPayload.lanBridgeURLs(port: port, adapterID: lanAdapter)
            guard let first = urls.first else { return "No LAN IP found" }
            if urls.count > 1 {
                return "\(first) (+\(urls.count - 1))"
            }
            return first
        }
        return BridgePairingPayload.localBridgeURL(port: port)
    }

    private var currentToken: String {
        authToken.isEmpty ? AppSettings.ensureBridgeAuthToken() : authToken
    }

    private var maskedToken: String {
        let token = currentToken
        guard token.count > 10 else { return "••••••" }
        return "••••••" + token.suffix(6)
    }

    private func copyToken() {
        copyToClipboard(currentToken)
        copiedMessage = "Token copied"
    }

    private func copyPairingJSON() {
        let payload = BridgePairingPayload.current()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8)
        else { return }
        copyToClipboard(text)
        copiedMessage = "JSON copied"
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Diagnostics

struct DiagnosticsSettingsView: View {
    @AppStorage(AppSettings.Keys.diagnosticsDebugMode) private var debugMode = false
    @AppStorage(AppSettings.Keys.diagnosticsDebugCaptureLimit) private var debugCaptureLimit = 10
    @State private var debugCaptureCount = 0

    var body: some View {
        Form {
            Section("Debug capture") {
                Toggle("Debug mode", isOn: $debugMode)
                Text("When enabled, Typeforme keeps the latest \(AppSettings.diagnosticsDebugCaptureLimit) captures: received audio, ASR transcript, and the selected correction request/result.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                IntegerSettingField(
                    title: "Keep captures",
                    value: $debugCaptureLimit,
                    range: 1...200,
                    suffix: "items"
                )
                HStack {
                    Text("Folder")
                    Spacer()
                    Text(AppPaths.debugCapturesDir.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Text("Stored captures")
                    Spacer()
                    Text("\(debugCaptureCount)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Reveal in Finder") {
                        try? AppPaths.ensureDirectories()
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.debugCapturesDir])
                        refreshDebugCaptureCount()
                    }
                    Button("Refresh") {
                        refreshDebugCaptureCount()
                    }
                    Button("Clear") {
                        DebugLogStore.clear()
                        refreshDebugCaptureCount()
                    }
                    .disabled(debugCaptureCount == 0)
                }
            }
            Section("Live logs") {
                HStack {
                    Text("Subsystem")
                    Spacer()
                    Text("com.typeforme.mac").foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("Open Console.app and filter by Subsystem to see categorized live logs (audio, asr, llm, hotkey, coordinator, …).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Crash reports") {
                Button("Reveal in Finder") {
                    let url = URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent("Library/Logs/DiagnosticReports")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Text("If Typeforme ever crashes, look for a Typeforme-*.ips file in ~/Library/Logs/DiagnosticReports. The first 30 lines (Exception Type / Termination Reason / Thread 0 backtrace) are usually enough to diagnose.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text(debugMode ? "Debug mode stores raw audio and text locally in the debug capture folder. Turn it off when you are done." : "Normal live logs use provider / latency / length / hash / error-code only. They do not include raw user text.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshDebugCaptureCount() }
        .onChange(of: debugMode) { _, _ in refreshDebugCaptureCount() }
        .onChange(of: debugCaptureLimit) { _, _ in
            DebugLogStore.prune()
            refreshDebugCaptureCount()
        }
    }

    private func refreshDebugCaptureCount() {
        debugCaptureCount = DebugLogStore.recentCount()
    }
}

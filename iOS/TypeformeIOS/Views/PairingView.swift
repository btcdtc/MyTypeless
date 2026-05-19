import SwiftUI
import UIKit

struct PairingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config: PairingConfig
    @State private var pairingJSON = ""
    @State private var parseError: String?
    @State private var parsedSuccessfully = false
    @State private var parsedSource = ""
    @State private var isPulling = false
    @State private var routeStatus: BridgeRouteStatus

    let onSave: (PairingConfig) -> Void

    init(config: PairingConfig, routeStatus: BridgeRouteStatus, onSave: @escaping (PairingConfig) -> Void) {
        self._config = State(initialValue: config)
        self._routeStatus = State(initialValue: routeStatus)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Open the Mac app, copy the pairing JSON, then paste it here. Pairing only stores connection details. Languages are an iOS override on the main screen, and the default mode follows Server Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Paste Pairing JSON") {
                    Button {
                        pastePairingJSON()
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    if !pairingJSON.isEmpty {
                        TextEditor(text: $pairingJSON)
                            .frame(minHeight: 100)
                            .font(.system(.caption, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: pairingJSON) { _, _ in
                                parsePairingJSON(pairingJSON)
                            }
                    }
                    if parsedSuccessfully {
                        Label("Pairing JSON parsed. Tap Save to apply.", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                    if let parseError {
                        Label(parseError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Bridge") {
                    LabeledContent("Local URL") {
                        TextField("http://192.168.…", text: localURLBinding)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    if config.localBridgeURLCandidates.count > 1 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(config.localBridgeURLCandidates.count) local candidates from the Mac")
                                .font(.footnote.weight(.medium))
                            ForEach(config.localBridgeURLCandidates, id: \.self) { url in
                                Text(url)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    LabeledContent("Cloud URL") {
                        TextField("https://…", text: $config.publicBridgeURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Token") {
                        SecureField("paste token", text: $config.token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    Button {
                        refreshFromMac(saveAfterRefresh: true)
                    } label: {
                        Label(isPulling ? "Pulling…" : "Refresh Server Settings", systemImage: "arrow.down.doc")
                    }
                    .disabled(isPulling || !config.hasAnyBridgeURL || config.token.isEmpty)
                }

                Section("Routing") {
                    PairingRouteRow(
                        title: "Local",
                        endpoint: primaryLocalEndpoint,
                        state: endpointState(
                            isConfigured: !config.localBridgeURLCandidates.isEmpty,
                            isChecked: routeStatus.localChecked,
                            isOK: routeStatus.localOK
                        ),
                        latencyMs: routeStatus.localLatencyMs,
                        isActive: routeStatus.activeKind == .local,
                        tint: .green
                    )
                    PairingRouteRow(
                        title: "Cloud",
                        endpoint: serverEndpoint,
                        state: endpointState(
                            isConfigured: !config.publicBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            isChecked: routeStatus.cloudChecked,
                            isOK: routeStatus.cloudOK
                        ),
                        latencyMs: routeStatus.cloudLatencyMs,
                        isActive: routeStatus.activeKind == .cloud,
                        tint: .blue
                    )
                    Button {
                        refreshRouteStatus()
                    } label: {
                        Label(isPulling ? "Checking…" : "Check Routes", systemImage: "arrow.clockwise")
                    }
                    .disabled(isPulling || !config.hasAnyBridgeURL || config.token.isEmpty)
                    Text("When Wi-Fi is active, Typeforme tries Local first. If Local is unavailable, it falls back to Cloud.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pairing")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(config)
                        dismiss()
                    }
                    .disabled(!config.hasAnyBridgeURL || config.token.isEmpty)
                }
            }
        }
    }

    private var primaryLocalEndpoint: String {
        if routeStatus.activeKind == .local, let activeURL = routeStatus.activeURL?.absoluteString {
            return activeURL
        }
        return config.localBridgeURLCandidates.first ?? "Not configured"
    }

    private var serverEndpoint: String {
        let trimmed = config.publicBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Not configured" : trimmed
    }

    private func endpointState(isConfigured: Bool, isChecked: Bool, isOK: Bool) -> String {
        if !isConfigured { return "Not configured" }
        if isOK { return "Available" }
        return isChecked ? "Unavailable" : "Not checked"
    }

    private var localURLBinding: Binding<String> {
        Binding {
            config.lanBridgeURL
        } set: { newValue in
            config.lanBridgeURL = newValue
            config.lanBridgeURLs = PairingConfig.uniqueBridgeURLs([newValue])
        }
    }

    private func refreshRouteStatus() {
        guard !isPulling else { return }
        isPulling = true
        parseError = nil
        Task {
            let route = await BridgeRouteResolver().resolve(config: config, probeAllEndpoints: true)
            await MainActor.run {
                routeStatus = route
                if route.activeKind == .local, let activeURL = route.activeURL?.absoluteString {
                    config.promoteLocalBridgeURL(activeURL)
                }
                isPulling = false
            }
        }
    }

    private func pastePairingJSON() {
        let pasted = UIPasteboard.general.string ?? ""
        guard !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parseError = "Clipboard is empty."
            parsedSuccessfully = false
            return
        }
        if pasted == pairingJSON {
            parsePairingJSON(pasted)
        } else {
            pairingJSON = pasted
            parsePairingJSON(pasted)
        }
    }

    private func parsePairingJSON(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parseError = nil
            parsedSuccessfully = false
            return
        }
        if trimmed == parsedSource, parsedSuccessfully { return }
        parseError = nil
        parsedSuccessfully = false
        guard let data = trimmed.data(using: .utf8) else {
            parseError = "Pasted text isn't valid UTF-8."
            return
        }
        do {
            var decoded = try JSONDecoder().decode(PairingConfig.self, from: data)
            decoded.languageIDs = config.languageIDs
            decoded.supportedLanguages = config.supportedLanguages
            decoded.correctionMode = config.correctionMode
            decoded.normalizeLanguageIDs()
            config = decoded
            parsedSuccessfully = true
            parsedSource = trimmed
            if decoded.hasAnyBridgeURL, !decoded.token.isEmpty {
                refreshFromMac(saveAfterRefresh: false)
            }
        } catch {
            parseError = "Couldn't parse as pairing JSON: \(error.localizedDescription)"
        }
    }

    private func refreshFromMac(saveAfterRefresh: Bool) {
        guard !isPulling else { return }
        parseError = nil
        let token = config.token
        isPulling = true
        Task {
            let route = await BridgeRouteResolver().resolve(config: config, probeAllEndpoints: true)
            guard let activeURL = route.activeURL else {
                await MainActor.run {
                    routeStatus = route
                    parseError = BridgeClientError.unauthorizedOrUnavailable.localizedDescription
                    isPulling = false
                }
                return
            }
            let client = BridgeClient(baseURL: activeURL, token: token)
            do {
                var settings = try await client.macSettings()
                settings.normalize()
                await MainActor.run {
                    routeStatus = route
                    if route.activeKind == .local {
                        config.promoteLocalBridgeURL(activeURL.absoluteString)
                    }
                    applyMacSettings(settings)
                    parsedSuccessfully = true
                    if saveAfterRefresh {
                        onSave(config)
                    }
                    isPulling = false
                }
            } catch {
                await MainActor.run {
                    parseError = error.localizedDescription
                    isPulling = false
                }
            }
        }
    }

    private func applyMacSettings(_ settings: BridgeMacSettingsPayload) {
        config.supportedLanguages = settings.supportedLanguages
        config.correctionMode = settings.correctionMode
        config.languageIDs = ASRLanguageSelection.validatedIDs(
            config.languageIDs,
            supportedOptions: config.supportedLanguageOptions
        )
        config.normalizeLanguageIDs()
    }

}

private struct PairingRouteRow: View {
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

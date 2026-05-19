import SwiftUI

/// Settings UI with a stable custom sidebar. Avoids the system
/// NavigationSplitView sidebar-toggle button, which can float into the
/// titlebar for this LSUIElement-hosted settings window.
struct SettingsView: View {
    @ObservedObject var dictionary: UserDictionaryStore
    @State private var selection: Section = .general
    @AppStorage(AppSettings.Keys.processingMode) private var processingModeRaw = ProcessingMode.client.rawValue

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case general      = "General"
        case server       = "Server"
        case recording    = "Recording"
        case asr          = "ASR"
        case correction   = "Correction"
        case prompts      = "Prompts"
        case dictionary   = "Vocabulary"
        case bridge       = "Bridge"
        case diagnostics  = "Diagnostics"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general:     return "gearshape"
            case .server:      return "desktopcomputer"
            case .recording:   return "waveform.circle"
            case .asr:         return "mic"
            case .correction:  return "text.badge.checkmark"
            case .prompts:     return "doc.text"
            case .dictionary:  return "book"
            case .bridge:      return "antenna.radiowaves.left.and.right"
            case .diagnostics: return "stethoscope"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 178)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            VStack(spacing: 0) {
                HStack {
                    Text(effectiveSelection.rawValue)
                        .font(.title2.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)

                Divider()

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onChange(of: processingModeRaw) { _, _ in
            if !visibleSections.contains(selection) {
                selection = .general
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(visibleSections) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .frame(width: 18)
                        Text(section.rawValue)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(selection == section ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == section ? Color.primary : Color.secondary)
            }
            Spacer()
        }
        .padding(10)
    }

    @ViewBuilder
    private var detail: some View {
        switch effectiveSelection {
        case .general:     GeneralSettingsView()
        case .server:      ClientServerSettingsView()
        case .recording:   RecordingSettingsView()
        case .asr:         ASRSettingsView()
        case .correction:  CorrectionSettingsView()
        case .prompts:     PromptsSettingsView()
        case .dictionary:  DictionarySettingsView(store: dictionary)
        case .bridge:      BridgeSettingsView()
        case .diagnostics: DiagnosticsSettingsView()
        }
    }

    private var processingMode: ProcessingMode {
        ProcessingMode(rawValue: processingModeRaw) ?? .client
    }

    private var visibleSections: [Section] {
        switch processingMode {
        case .server:
            return [.general, .recording, .asr, .correction, .prompts, .dictionary, .bridge, .diagnostics]
        case .client:
            return [.general, .server, .recording, .diagnostics]
        }
    }

    private var effectiveSelection: Section {
        visibleSections.contains(selection) ? selection : .general
    }
}

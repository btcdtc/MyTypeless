import SwiftUI

/// State-driven SF Symbol for the menu-bar status item. Passed as the
/// `label:` closure of `MenuBarExtra` so SwiftUI re-renders the icon
/// whenever `coordinator.state` changes — no manual NSStatusItem button
/// patching needed.
struct MenuBarLabel: View {
    @ObservedObject var coordinator: DictationCoordinator

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        switch coordinator.state {
        case .idle:                                  return "mic"
        case .recording:                             return "mic.fill"
        case .transcribing, .correcting, .inserting: return "waveform"
        case .preview:                               return "doc.text.magnifyingglass"
        case .success:                               return "checkmark.circle.fill"
        case .error:                                 return "exclamationmark.triangle.fill"
        }
    }
}

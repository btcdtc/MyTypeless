import SwiftUI

enum LanguageDisplay {
    static func summary(for ids: Set<String>, options: [ASRLanguageOption] = ASRLanguageSelection.all) -> String {
        let names = ASRLanguageSelection.displayNames(for: Array(ids), supportedOptions: options)
        if names.isEmpty { return "None" }
        if names.count <= 2 { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)"
    }
}

struct LanguageSelectionView: View {
    @Binding var selection: Set<String>
    let options: [ASRLanguageOption]
    @State private var searchText = ""

    init(selection: Binding<Set<String>>, options: [ASRLanguageOption] = ASRLanguageSelection.all) {
        self._selection = selection
        self.options = options.isEmpty ? ASRLanguageSelection.all : options
    }

    var body: some View {
        List {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Common") {
                    ForEach(commonLanguages) { option in
                        languageRow(option)
                    }
                }

                Section("Supported Languages") {
                    ForEach(otherLanguages) { option in
                        languageRow(option)
                    }
                }
            } else {
                Section("Matches") {
                    ForEach(filteredLanguages) { option in
                        languageRow(option)
                    }
                }
            }
        }
        .navigationTitle("Languages")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
        .onAppear(perform: clampSelection)
    }

    private var commonLanguages: [ASRLanguageOption] {
        options
            .filter(\.isCommon)
            .sorted { ($0.commonRank ?? .max) < ($1.commonRank ?? .max) }
    }

    private var otherLanguages: [ASRLanguageOption] {
        options.filter { !$0.isCommon }
    }

    private var filteredLanguages: [ASRLanguageOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return options }
        return options.filter { option in
            option.id.lowercased().contains(query)
                || option.displayName.lowercased().contains(query)
                || option.whisperCode.lowercased().contains(query)
        }
    }

    private func languageRow(_ option: ASRLanguageOption) -> some View {
        Button {
            toggle(option.id)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.displayName)
                    Text(option.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selection.contains(option.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
    }

    private func toggle(_ id: String) {
        if selection.contains(id), selection.count > 1 {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        clampSelection()
    }

    private func clampSelection() {
        selection = Set(ASRLanguageSelection.validatedIDs(Array(selection), supportedOptions: options))
    }
}

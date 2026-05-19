import Foundation

/// JSON-file-backed speech vocabulary. Entries are used as correction
/// candidates rather than unconditional text-expansion replacements.
@MainActor
final class UserDictionaryStore: ObservableObject {
    @Published private(set) var entries: [DictionaryEntry] = []
    private let url: URL

    init(url: URL = AppPaths.userDictionaryFile) {
        self.url = url
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: url) else {
            entries = []
            return
        }
        do {
            entries = try JSONDecoder().decode([DictionaryEntry].self, from: data)
                .filter(\.isValid)
            save()
        } catch {
            Log.store.error("user dictionary decode failed: \(error.localizedDescription)")
            entries = []
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.store.error("user dictionary save failed: \(error.localizedDescription)")
        }
    }

    func add(
        type: String,
        surface: String
    ) {
        let entry = DictionaryEntry(
            type: type,
            surface: surface
        )
        guard entry.isValid else { return }
        entries.append(entry)
        save()
    }

    func update(_ entry: DictionaryEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        save()
    }

    func remove(_ entry: DictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func remove(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    /// Stable snapshot — spec §17 wants the vocabulary segment of the prompt to
    /// be cacheable when the candidate set is unchanged.
    nonisolated func sortedSnapshot(_ snapshot: [DictionaryEntry]) -> [DictionaryEntry] {
        snapshot.sorted {
            if $0.type != $1.type { return $0.type < $1.type }
            return $0.surface < $1.surface
        }
    }

    func sortedSnapshot() -> [DictionaryEntry] {
        sortedSnapshot(entries)
    }
}

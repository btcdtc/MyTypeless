import Foundation

enum ModelAutoInstallError: LocalizedError {
    case emptyURL(label: String)
    case invalidURL(String)
    case httpStatus(Int, label: String)

    var errorDescription: String? {
        switch self {
        case .emptyURL(let label):
            return "Download URL is empty for \(label)"
        case .invalidURL(let value):
            return "Invalid model download URL: \(value)"
        case .httpStatus(let status, let label):
            return "\(label) download failed with HTTP \(status)"
        }
    }
}

enum ModelInstallRegistry {
    private static let lock = NSLock()
    private static var activeLabelsByPath: [String: String] = [:]

    static func markInstalling(path: String, label: String) {
        lock.lock()
        activeLabelsByPath[path] = label
        lock.unlock()
    }

    static func markFinished(path: String) {
        lock.lock()
        activeLabelsByPath.removeValue(forKey: path)
        lock.unlock()
    }

    static func isInstalling(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeLabelsByPath[path] != nil
    }
}

actor ModelAutoInstaller {
    static let shared = ModelAutoInstaller()

    private var tasks: [String: Task<Void, Error>] = [:]

    func ensureFile(atPath path: String, downloadURLString: String, label: String) async throws {
        if FileManager.default.fileExists(atPath: path) { return }

        let trimmedURL = downloadURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            throw ModelAutoInstallError.emptyURL(label: label)
        }
        guard let url = URL(string: trimmedURL) else {
            throw ModelAutoInstallError.invalidURL(trimmedURL)
        }

        let key = "\(path)|\(url.absoluteString)"
        if let existing = tasks[key] {
            try await existing.value
            return
        }

        let destination = URL(fileURLWithPath: path)
        let task = Task {
            try await Self.download(from: url, to: destination, label: label)
        }
        tasks[key] = task
        defer { tasks[key] = nil }
        try await task.value
    }

    private static func download(from url: URL, to destination: URL, label: String) async throws {
        Log.store.notice("auto-installing model: \(label, privacy: .public)")
        ModelInstallRegistry.markInstalling(path: destination.path, label: label)
        defer { ModelInstallRegistry.markFinished(path: destination.path) }

        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw ModelAutoInstallError.httpStatus(http.statusCode, label: label)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporaryURL, to: destination)
        Log.store.info("model auto-installed: \(destination.lastPathComponent, privacy: .public)")
    }
}

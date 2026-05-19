import Foundation

enum ProcessingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case server
    case client

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .server: return "Server"
        case .client: return "Client"
        }
    }

    var helpText: String {
        switch self {
        case .server:
            return "This Mac records, transcribes, corrects, and can expose the Bridge for other devices."
        case .client:
            return "This Mac records locally, sends audio to another Typeforme Bridge, then inserts the returned text here."
        }
    }
}

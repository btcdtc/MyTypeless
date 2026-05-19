import Foundation

/// Spec §10. ASR is purely audio-file → text. No partial streaming in v1.
/// Conforming types are used only from the main actor (coordinator), so this
/// protocol doesn't require Sendable conformance.
protocol ASRService {
    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String
}

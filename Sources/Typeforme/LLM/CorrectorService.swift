import Foundation

/// Backends transform a `CorrectionRequest` into a `CorrectionResult`.
/// Per spec §11 every backend has a hard timeout (`timeoutMs`); on cold start
/// the orchestrator uses a longer warmup timeout.
protocol CorrectorService: Sendable {
    var kind: CorrectionBackendKind { get }
    func correct(_ request: CorrectionRequest, timeoutMs: Int) async throws -> CorrectionResult
    func complete(system: String, user: String, timeoutMs: Int) async throws -> String
}

enum CorrectorError: LocalizedError, Equatable {
    case timeout
    case unavailable(String)
    case validationFailed(String)
    case requestFailed(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .timeout:               return "Correction timed out"
        case .unavailable(let why):  return "Backend unavailable: \(why)"
        case .validationFailed(let why): return "Output validation failed: \(why)"
        case .requestFailed(let why):    return "Backend error: \(why)"
        case .empty:                 return "Backend returned no usable output"
        }
    }
}

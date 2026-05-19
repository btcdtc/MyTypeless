import Foundation

enum CorrectionAction: String, Codable, Sendable {
    case commit
}

enum CorrectionRisk: String, Codable, Sendable {
    case low, medium, high
}

struct CorrectionResult: Codable, Sendable, Equatable {
    var action: CorrectionAction
    var text: String
    var risk: CorrectionRisk
}

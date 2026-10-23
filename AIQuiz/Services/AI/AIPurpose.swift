import Foundation

/// What an AI call is for. Each purpose routes to an endpoint (SPEC §8.2, S-2).
enum AIPurpose: String, Codable, CaseIterable, Identifiable, Sendable {
    case generation
    case grading
    case summary
    case chat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .generation: return "Quiz generation"
        case .grading: return "Grading and explanations"
        case .summary: return "Summaries and study notes"
        case .chat: return "Tutor chat"
        }
    }
}

/// Whether Apple's on-device model can run on this device.
struct AppleAvailability: Sendable, Equatable {
    var isAvailable: Bool
    var reason: String

    static let unavailable = AppleAvailability(isAvailable: false, reason: "Not available in this configuration.")
}

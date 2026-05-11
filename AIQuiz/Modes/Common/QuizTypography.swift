import SwiftUI

enum QuizFontSize: Int, CaseIterable, Identifiable, Codable {
    case small = 0
    case medium = 1
    case large = 2
    case extraLarge = 3
    case huge = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        case .huge: return "Huge"
        }
    }

    var promptPoints: CGFloat {
        switch self {
        case .small: return 22
        case .medium: return 28
        case .large: return 36
        case .extraLarge: return 46
        case .huge: return 60
        }
    }

    var bodyPoints: CGFloat {
        switch self {
        case .small: return 17
        case .medium: return 20
        case .large: return 26
        case .extraLarge: return 32
        case .huge: return 40
        }
    }

    var emphasisPoints: CGFloat {
        switch self {
        case .small: return 19
        case .medium: return 23
        case .large: return 30
        case .extraLarge: return 38
        case .huge: return 48
        }
    }

    var captionPoints: CGFloat {
        switch self {
        case .small: return 13
        case .medium: return 15
        case .large: return 18
        case .extraLarge: return 22
        case .huge: return 26
        }
    }

    var promptFont: Font { .system(size: promptPoints, weight: .semibold, design: .rounded) }
    var bodyFont: Font { .system(size: bodyPoints) }
    var emphasisFont: Font { .system(size: emphasisPoints, weight: .semibold) }
    var captionFont: Font { .system(size: captionPoints) }
}

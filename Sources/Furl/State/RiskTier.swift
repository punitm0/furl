import Foundation

/// The three risk words shown everywhere in the app (WhySafe board). Display only: scanners keep
/// their own `RiskLevel`, and nothing saved depends on these labels.
enum RiskTier: String, CaseIterable, Sendable, Hashable {
    case safe
    case checkFirst
    case permanent

    /// One word on the chip.
    var label: String {
        switch self {
        case .safe: return "Safe"
        case .checkFirst: return "Check first"
        case .permanent: return "Permanent"
        }
    }

    /// The legend line at the top of each list.
    var meaning: String {
        switch self {
        case .safe: return "comes back by itself, or you can rebuild it."
        case .checkFirst: return "probably fine, but only you know."
        case .permanent: return "can't be undone."
        }
    }

    /// Spoken by VoiceOver for the chip.
    var accessibilityLabel: String { "\(label): \(meaning)" }
}

extension RiskLevel {
    /// "Moderate" and "Review" both read as Check first.
    var tier: RiskTier { self == .safe ? .safe : .checkFirst }
}

extension InspectorSafety {
    /// Review and caution both read as Check first; Permanent is shown separately when the item skips the Trash.
    var tier: RiskTier { self == .safe ? .safe : .checkFirst }
}

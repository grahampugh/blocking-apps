import SwiftUI

/// How strongly an app is likely to block an unattended logout / shutdown /
/// software update.
enum Severity: String, Sendable, CaseIterable, Comparable {
    /// A genuine, current blocker: an open modal/save sheet, an unresponsive
    /// app, or other GUI login sessions.
    case high = "HIGH"
    /// Informational: the app has open windows but no detectable dirty state.
    /// It *might* prompt to save on quit, but is not actively blocking now.
    case medium = "MEDIUM"
    /// Low signal (reserved; not currently emitted).
    case low = "LOW"

    /// Sort order — lower rank sorts first (HIGH at the top).
    var rank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    /// Only HIGH is shown fully capitalised, matching the shell tool's output.
    var displayLabel: String {
        self == .high ? rawValue : rawValue.lowercased()
    }

    /// Title for the list section that groups apps of this severity.
    var sectionTitle: String {
        switch self {
        case .high: return "Actively blocking"
        case .medium: return "Open windows (informational)"
        case .low: return "Other"
        }
    }

    var tint: Color {
        switch self {
        case .high: return .red
        case .medium: return .orange
        case .low: return .secondary
        }
    }

    static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rank < rhs.rank
    }
}

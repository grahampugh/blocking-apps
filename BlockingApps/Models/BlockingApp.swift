import Foundation

/// One app (or pseudo-entry, like "Other login sessions") that may block an
/// unattended update, with the reasons it was flagged.
struct BlockingApp: Identifiable, Sendable, Hashable {
    let name: String
    let bundleID: String
    let pid: pid_t
    let severity: Severity
    let reasons: [String]
    /// App bundle location, used to load the icon on the main actor. `nil` for
    /// pseudo-entries like "Other login sessions". (`URL` is Sendable; the
    /// icon itself is loaded in the view, not carried across the scan boundary.)
    var bundleURL: URL? = nil

    /// Stable identity for SwiftUI lists. Bundle id is unique per running app;
    /// the pseudo-entries use a sentinel bundle id plus their name.
    var id: String { "\(bundleID)#\(pid)#\(name)" }

    /// Human-readable, "; "-joined reasons, matching the shell tool.
    var reasonText: String { reasons.joined(separator: "; ") }
}

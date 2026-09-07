import AppKit
import ApplicationServices

/// Thin wrapper over the Accessibility (a.k.a. "Device Control and Data
/// Access" on macOS 27+) TCC grant.
///
/// Unlike the shell version, this app talks to the Accessibility API directly
/// (`AXUIElementCreateApplication`), so it needs ONLY Accessibility — no
/// Automation / Apple Events grant, and no System Events dependency at all.
enum AccessibilityAuthorization {

    /// Whether this process is currently trusted to use the Accessibility API.
    /// Cheap to call; safe to poll before each scan.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility if not already trusted. macOS
    /// shows the standard system alert and deep-links to the settings pane;
    /// the grant only takes effect for a freshly launched process.
    @discardableResult
    static func promptIfNeeded() -> Bool {
        // Literal value of kAXTrustedCheckOptionPrompt; referencing the global
        // constant directly trips Swift 6 concurrency-safety checks.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Open the relevant Privacy & Security settings pane directly.
    static func openSettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }
}

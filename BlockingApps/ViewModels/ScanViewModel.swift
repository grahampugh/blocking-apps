import AppKit
import Foundation
import Observation

/// Drives the UI: holds scan results and authorization state, and runs the
/// (potentially slow) scan off the main actor.
@MainActor
@Observable
final class ScanViewModel {
    private(set) var results: [BlockingApp] = []
    private(set) var isScanning = false
    private(set) var isAuthorized = AccessibilityAuthorization.isTrusted
    private(set) var lastScan: Date?

    init() {
        // The Accessibility grant only takes effect after the user toggles it
        // in System Settings and returns to us; `AXIsProcessTrusted()` read once
        // at launch goes stale. Re-check every time the app becomes active so
        // the banner clears (and we scan) as soon as permission is granted,
        // without needing a relaunch. The observer lives for the app session
        // (closing the window quits the app), so no explicit teardown is needed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAuthorization()
            }
        }
    }

    /// Re-read the live authorization state. If it just flipped to granted,
    /// kick off a scan so results appear immediately.
    func refreshAuthorization() {
        let nowTrusted = AccessibilityAuthorization.isTrusted
        let wasTrusted = isAuthorized
        isAuthorized = nowTrusted
        if nowTrusted && !wasTrusted {
            Task { await rescan() }
        }
    }

    /// HIGH-severity entries only — the genuine blockers.
    var blockers: [BlockingApp] { results.filter { $0.severity == .high } }

    /// Results grouped by severity, in display order (HIGH first). Only
    /// severities that have at least one entry are included.
    var sections: [(severity: Severity, apps: [BlockingApp])] {
        Severity.allCases
            .sorted { $0 < $1 }
            .compactMap { severity in
                let apps = results.filter { $0.severity == severity }
                return apps.isEmpty ? nil : (severity, apps)
            }
    }

    /// Re-check authorization, then scan if allowed.
    func rescan() async {
        isAuthorized = AccessibilityAuthorization.isTrusted
        guard isAuthorized else {
            results = []
            return
        }

        isScanning = true
        defer { isScanning = false }

        results = await Task.detached(priority: .userInitiated) {
            BlockerScanner.scan()
        }.value
        lastScan = Date()
    }

    /// Trigger the system Accessibility prompt.
    func requestAuthorization() {
        AccessibilityAuthorization.promptIfNeeded()
    }

    func openAccessibilitySettings() {
        AccessibilityAuthorization.openSettings()
    }

    /// Bring the clicked app to the foreground. Uses only the pid we already
    /// hold — `NSRunningApplication.activate()` needs no extra permission.
    /// No-op for pseudo-entries (e.g. "Other login sessions", pid 0).
    func activate(_ app: BlockingApp) {
        guard app.pid > 0 else { return }
        NSRunningApplication(processIdentifier: app.pid)?.activate()
    }
}

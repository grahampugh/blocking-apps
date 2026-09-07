import AppKit
import ApplicationServices
import Darwin

/// Scans running GUI apps for signals that they would block an unattended
/// logout / shutdown / software update.
///
/// This is the native reimplementation of `check-blocking-apps.sh`. The key
/// robustness win over the shell version: instead of spawning ~60+ `osascript`
/// processes and routing everything through System Events, it queries the
/// Accessibility API directly and sets a per-app messaging timeout, so one
/// wedged app can never hang the whole scan.
///
/// Detection tiers (unchanged from the shell tool's reasoning):
///   * HIGH   — open modal/save sheet, unresponsive app, an elevated (root)
///              child session (e.g. `sudo` under a terminal), other login sessions.
///   * MEDIUM — has open standard windows but no detectable dirty state
///              (informational; not actively blocking).
/// Unsaved-document detection is best-effort: only apps that expose an
/// `AXModified` attribute or an "Edited"/"Modified" title suffix can be caught.
/// Autosaving apps (TextEdit, Preview, …) have no unsaved state to find, and
/// some apps (e.g. KeePassXC) hide their dirty state from Accessibility
/// entirely. The universal signal remains the modal sheet an app raises at
/// quit time.
enum BlockerScanner {

    /// Apple's always-running shell pieces we never flag.
    static let ignoredBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
    ]

    /// Per-app AX messaging timeout (seconds). Bounds every attribute query so
    /// an unresponsive app times out fast instead of blocking the scan.
    static let messagingTimeout: Float = 0.5

    /// Run a full scan. Synchronous and `nonisolated`; call it off the main
    /// actor (e.g. from `Task.detached`) so AX timeouts never stall the UI.
    static func scan() -> [BlockingApp] {
        var results: [BlockingApp] = []

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        // Snapshot the process tree once so we can spot elevated (root)
        // descendants — e.g. a `sudo`/`su` session under a terminal, which
        // makes that app refuse to quit.
        let childMap = Dictionary(grouping: processTable(), by: { $0.ppid })

        // Never flag ourselves — it's obvious we're open and we don't block a
        // shutdown (we also declare NSSupportsSuddenTermination).
        let selfBundleID = Bundle.main.bundleIdentifier

        for app in apps {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != selfBundleID,
                  !ignoredBundleIDs.contains(bundleID),
                  app.processIdentifier > 0
            else { continue }

            let name = app.localizedName ?? bundleID
            let hasRootSession = hasRootDescendant(of: app.processIdentifier, childMap: childMap)
            if let entry = inspect(app: app, name: name, bundleID: bundleID,
                                   hasRootSession: hasRootSession) {
                results.append(entry)
            }
        }

        // Other GUI login sessions also block an unattended install.
        let others = otherLoginSessions()
        if !others.isEmpty {
            results.append(
                BlockingApp(
                    name: "Other login sessions",
                    bundleID: "-",
                    pid: 0,
                    severity: .high,
                    reasons: ["users logged in: \(others.joined(separator: ", "))"]
                )
            )
        }

        return results.sorted {
            $0.severity != $1.severity ? $0.severity < $1.severity
                                       : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Per-app inspection

    private static func inspect(app: NSRunningApplication, name: String, bundleID: String,
                                hasRootSession: Bool) -> BlockingApp? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, messagingTimeout)

        // Fetch the window list. A timeout here means the app isn't servicing
        // its UI run loop — i.e. not responding, a genuine hard blocker.
        var windowsValue: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue)

        if err == .cannotComplete {
            var reasons = ["not responding (UI query timed out)"]
            if hasRootSession { reasons.append("elevated (root) session running — e.g. sudo") }
            return BlockingApp(name: name, bundleID: bundleID, pid: app.processIdentifier,
                               severity: .high, reasons: reasons,
                               bundleURL: app.bundleURL)
        }

        let windows = (windowsValue as? [AXUIElement]) ?? []

        var modalCount = 0
        var unsavedCount = 0
        var standardWindows = 0

        for window in windows {
            let subrole = copyString(window, kAXSubroleAttribute as CFString)
            switch subrole {
            case "AXStandardWindow": standardWindows += 1
            case "AXDialog", "AXSystemDialog": modalCount += 1
            default: break
            }

            // An explicitly modal window blocks input until dismissed.
            if copyBool(window, "AXModal" as CFString) == true { modalCount += 1 }

            // Attached save/confirm sheets appear as AXSheet children.
            if let children = copyArray(window, kAXChildrenAttribute as CFString) {
                modalCount += children.filter {
                    copyString($0, kAXRoleAttribute as CFString) == "AXSheet"
                }.count
            }

            // Best-effort unsaved detection on document windows.
            if copyValue(window, "AXDocument" as CFString) != nil {
                if copyBool(window, "AXModified" as CFString) == true {
                    unsavedCount += 1
                } else if let title = copyString(window, kAXTitleAttribute as CFString),
                          title.hasSuffix("Edited") || title.hasSuffix("Modified") {
                    unsavedCount += 1
                }
            }
        }

        var reasons: [String] = []
        var severity: Severity = .low

        // A root/elevated child (sudo, su) makes the app refuse to quit.
        if hasRootSession {
            reasons.append("elevated (root) session running — e.g. sudo")
            severity = .high
        }
        if modalCount > 0 {
            reasons.append("open modal dialog/sheet (\(modalCount))")
            severity = .high
        }
        if unsavedCount > 0 {
            reasons.append("\(unsavedCount) unsaved document(s)")
            severity = .high
        }
        // Informational only: open windows but no hard-blocker signal.
        if reasons.isEmpty && standardWindows > 0 {
            reasons.append("\(standardWindows) open window(s), no unsaved changes detected")
            severity = .medium
        }

        guard !reasons.isEmpty else { return nil }
        return BlockingApp(name: name, bundleID: bundleID, pid: app.processIdentifier,
                           severity: severity, reasons: reasons, bundleURL: app.bundleURL)
    }

    // MARK: - Accessibility attribute helpers

    private static func copyValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value : nil
    }

    private static func copyString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        copyValue(element, attribute) as? String
    }

    private static func copyArray(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement]? {
        copyValue(element, attribute) as? [AXUIElement]
    }

    /// CFBoolean does not bridge to `Bool` via `as?`, so check the type id.
    private static func copyBool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        guard let value = copyValue(element, attribute) else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        return (value as? NSNumber)?.boolValue
    }

    // MARK: - Process tree / elevated sessions

    private struct ProcInfo {
        let pid: pid_t
        let ppid: pid_t
        let ruid: uid_t
    }

    /// Snapshot every process (pid, parent pid, real uid) via sysctl. Readable
    /// by any user for all processes — no special entitlement needed.
    private static func processTable() -> [ProcInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        let count = size / stride
        return procs.prefix(count).map { p in
            ProcInfo(pid: p.kp_proc.p_pid,
                     ppid: p.kp_eproc.e_ppid,
                     ruid: p.kp_eproc.e_pcred.p_ruid)
        }
    }

    /// True if any descendant of `pid` runs with real uid 0 (root) — i.e. a
    /// `sudo`/`su` session that blocks the parent app from quitting.
    private static func hasRootDescendant(of pid: pid_t, childMap: [pid_t: [ProcInfo]]) -> Bool {
        var stack = childMap[pid] ?? []
        var seen = Set<pid_t>()
        while let proc = stack.popLast() {
            guard seen.insert(proc.pid).inserted else { continue }
            if proc.ruid == 0 { return true }
            stack.append(contentsOf: childMap[proc.pid] ?? [])
        }
        return false
    }

    // MARK: - Login sessions

    /// Console/GUI users with active sessions other than the current user,
    /// read natively via utmpx (no shelling out to `who`).
    private static func otherLoginSessions() -> [String] {
        let me = NSUserName()
        var users = Set<String>()

        setutxent()
        defer { endutxent() }
        while let entry = getutxent() {
            guard Int32(entry.pointee.ut_type) == USER_PROCESS else { continue }
            let user = withUnsafeBytes(of: entry.pointee.ut_user) { raw -> String in
                let bytes = raw.prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
            if !user.isEmpty && user != me {
                users.insert(user)
            }
        }
        return users.sorted()
    }
}

# Blocking Apps

A native macOS app that lists running apps likely to block an unattended
logout / shutdown / software update ("Later Tonight" install), with a reason
for each.

## Why a SwiftUI app?

- **Direct Accessibility API.** Uses `AXUIElementCreateApplication` and reads
  window/attribute data in-process. This means **only one TCC grant is required: Accessibility**
  ("Device Control and Data Access" on macOS 27+).
- **Bounded per-app queries.** `AXUIElementSetMessagingTimeout` caps every
  attribute read, so a wedged app times out fast (and is reported as *not
  responding*).
- **Native permission check.** `AXIsProcessTrusted()` is used to check for required permissions;
  the UI shows an actionable banner and can open the settings pane.
- **Stable TCC identity.** A signed, notarised `.app` bundle keeps its
  Accessibility grant across launches.

## Detection tiers

| Severity | Meaning |
|----------|---------|
| **HIGH** | Genuine current blocker: open modal/save sheet, unresponsive app, or other GUI login sessions. |
| **medium** | Informational: app has open windows but no detectable dirty state. It *might* prompt to save on quit; not actively blocking. |

### Unsaved-document detection is best-effort

There is no reliable, cross-app way to detect unsaved work via Accessibility:

- Autosaving apps (TextEdit, Preview, Pages, Notes…) have no unsaved state.
- Some apps (e.g. BBEdit) preserve unsaved text and never go "dirty".
- Others (e.g. KeePassXC) are genuinely dirty but sanitise their AX title and
  expose no `AXModified` attribute.

So Blocking Apps only catches apps that advertise an `AXModified` attribute or an
"Edited"/"Modified" title suffix. The universal signal is the modal sheet an
app raises at quit time, which the HIGH tier catches.

### Bespoke detections

1. Terminal-like apps (e.g. Terminal, iTerm2, kitty) that have an open root session are detected.
2. Blocking Apps itself is removed from the "open" list - it will never be a blocking app.

## Requirements

- macOS 26.0+
- Xcode 26+ (for the macOS 26 SDK) to build
- Accessibility permission granted to the app on first run

## Build

```bash
# Debug build (unsigned)
make

# Full signed + notarised release (.app, .pkg, .dmg)
make release

# Individual steps
make pkg      # signed installer from an existing release .app
make dmg      # disk image from an existing release .app
make github   # publish a GitHub pre-release from built artifacts
make clean
```

Signing uses the **Graham Pugh** Developer ID identities.

## App icon

The icon is an **Icon Composer** document, `BlockingApps/Blocking Apps.icon`
(a power glyph with a red no-entry sign over it, Liquid Glass treatment). The
target's `ASSETCATALOG_COMPILER_APPICON_NAME` is set to `Blocking Apps`, so
Xcode compiles the `.icon` into the app.

To edit it, open `Blocking Apps.icon` in Icon Composer (Xcode ▸ Open Developer
Tool ▸ Icon Composer). Its layers were generated from SF Symbols by
[`scripts/export-symbol-layers.swift`](scripts/export-symbol-layers.swift),
which renders each symbol to a filled, transparent 1024px PNG in
`scripts/icon-layers/` — a reliable substitute for SF Symbols' own SVG export,
which tends to import into Icon Composer with no fill.

## Project layout

```
BlockingApps.xcodeproj
BlockingApps/
  BlockingAppsApp.swift          # @main App entry
  Views/ContentView.swift        # SwiftUI UI + authorization banner
  ViewModels/ScanViewModel.swift # @Observable, runs the scan off-main
  Services/
    BlockerScanner.swift         # Accessibility scan (the core logic)
    AccessibilityAuthorization.swift
  Models/
    BlockingApp.swift
    Severity.swift
  Blocking Apps.icon             # Icon Composer app icon
  Assets.xcassets
scripts/
  export-symbol-layers.swift     # regenerate SF Symbol icon layers
Makefile
```

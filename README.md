# Blocking Apps

A native macOS app that lists running apps likely to block an unattended
logout / shutdown / software update ("Later Tonight" install), with a reason
for each.

It is the Swift reimplementation of the `check-blocking-apps.sh` script (in
[osx-scripts](https://github.com/grahampugh/osx-scripts)). The shell version
worked but was fragile: it spawned dozens of `osascript`/System Events calls
per run, needed both Automation **and** Accessibility grants, and could hang on
a single unresponsive app.

## Why the rewrite is more robust

- **Direct Accessibility API.** Uses `AXUIElementCreateApplication` and reads
  window/attribute data in-process — no `osascript`, no System Events, no
  Apple Events. This means **only one TCC grant is required: Accessibility**
  ("Device Control and Data Access" on macOS 27+).
- **Bounded per-app queries.** `AXUIElementSetMessagingTimeout` caps every
  attribute read, so a wedged app times out fast (and is reported as *not
  responding*) instead of stalling the whole scan.
- **Native permission check.** `AXIsProcessTrusted()` replaces the shell
  preflight; the UI shows an actionable banner and can open the settings pane.
- **Stable TCC identity.** A signed, notarised `.app` bundle keeps its
  Accessibility grant across launches — a bare CLI binary does not.

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

So the app only catches apps that advertise an `AXModified` attribute or an
"Edited"/"Modified" title suffix. The universal signal is the modal sheet an
app raises at quit time, which the HIGH tier catches.

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

Signing uses the **Graham Pugh** Developer ID identities (team `C96ALZKYH6`),
matching the `plist-yaml-plist-swift` project. Configure a notarytool keychain
profile once:

```bash
xcrun notarytool store-credentials graham-notary-profile-blockingapps \
    --apple-id <apple-id> --team-id C96ALZKYH6 --password <app-specific-password>
```

Override any signing value on the command line, e.g.
`make release NOTARY_PROFILE=other-profile`.

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

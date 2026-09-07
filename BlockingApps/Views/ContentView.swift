import AppKit
import SwiftUI

struct ContentView: View {
    @State private var model = ScanViewModel()

    var body: some View {
        VStack(spacing: 0) {
            if !model.isAuthorized {
                AuthorizationBanner(model: model)
                Divider()
            }

            resultsList

            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await model.rescan() }
    }

    @ViewBuilder
    private var resultsList: some View {
        if model.isAuthorized && model.results.isEmpty && !model.isScanning {
            ContentUnavailableView(
                "No likely blockers found",
                systemImage: "checkmark.circle",
                description: Text("No apps look likely to block an unattended update right now.")
            )
        } else {
            List {
                ForEach(model.sections, id: \.severity) { section in
                    Section(section.severity.sectionTitle) {
                        ForEach(section.apps) { app in
                            if app.pid > 0 {
                                Button {
                                    model.activate(app)
                                } label: {
                                    BlockingAppRow(app: app)
                                }
                                .buttonStyle(.plain)
                                .help("Bring \(app.name) to the front")
                            } else {
                                BlockingAppRow(app: app)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.isScanning && model.results.isEmpty {
                    ProgressView("Scanning…")
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let last = model.lastScan {
                Text("Last scan \(last.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await model.rescan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning || !model.isAuthorized)
        }
        .padding(12)
    }
}

private struct BlockingAppRow: View {
    let app: BlockingApp

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.body.weight(.medium))
                Text(app.reasonText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// The app's Finder icon, loaded on the main actor from its bundle URL.
    /// Falls back to an SF Symbol for pseudo-entries (no bundle) or entries
    /// whose icon can't be resolved.
    @ViewBuilder
    private var icon: some View {
        if let url = app.bundleURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "person.2.circle")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AuthorizationBanner: View {
    let model: ScanViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility permission needed")
                    .font(.headline)
                Text("Blocking Apps reads other apps' windows to detect open dialogs and unsaved work. Grant Accessibility (\u{201C}Device Control and Data Access\u{201D} on macOS 27+), then relaunch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Request Permission…") { model.requestAuthorization() }
                    Button("Open Settings") { model.openAccessibilitySettings() }
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.08))
    }
}

#Preview {
    ContentView()
}

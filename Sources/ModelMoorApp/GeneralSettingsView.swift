import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: UpdateController

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch ModelMoor at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Text("Configured connections start in the menu bar without opening the main window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics and Privacy") {
                Text("ModelMoor records a bounded, redacted runtime history. API keys and inference content are never included.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy Diagnostic Summary") {
                    Task { await model.copyDiagnosticSummary() }
                }
            }

            Section("Software Updates") {
                LabeledContent("Current Version", value: updates.currentVersion)
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updates.automaticChecksEnabled },
                    set: { updates.setAutomaticChecksEnabled($0) }
                ))

                VStack(alignment: .leading, spacing: 4) {
                    Text(updates.statusText)
                    if let lastCheckedAt = updates.lastCheckedAt {
                        Text("Last checked \(lastCheckedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button(updates.isChecking ? "Checking…" : "Check Now") {
                        Task { _ = await updates.checkNow() }
                    }
                    .disabled(updates.isChecking)

                    if let release = updates.availableRelease {
                        Button(release.downloadURL == nil ? "View Release…" : "Download Update…") {
                            updates.download(release)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

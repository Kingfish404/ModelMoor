import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel

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
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

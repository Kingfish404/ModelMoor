import Foundation
import ModelMoorSystem
import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: UpdateController

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch \(model.runtimeProfile.displayName) at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .disabled(!model.runtimeProfile.supportsLaunchAtLogin)
                Text(AppLocalization.string(model.runtimeProfile.supportsLaunchAtLogin
                     ? "Configured connections start in the menu bar without opening the main window."
                     : "Login launch is disabled for development builds."))
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

            Section("Persistent Storage") {
                persistenceRow(
                    title: AppLocalization.string("Configuration"),
                    detail: AppLocalization.string("SSH connections, endpoints, routes, and gateway settings. Schema backups are kept in the same folder."),
                    url: model.runtimeProfile.configurationURL,
                    directoryURL: model.runtimeProfile.configurationURL.deletingLastPathComponent()
                )

                if let legacyURL = model.runtimeProfile.legacyConfigurationURL,
                   FileManager.default.fileExists(atPath: legacyURL.path) {
                    persistenceRow(
                        title: AppLocalization.string("Legacy Configuration"),
                        detail: AppLocalization.string("Retained as an unchanged migration source for older ModelMoor versions."),
                        url: legacyURL,
                        directoryURL: legacyURL.deletingLastPathComponent()
                    )
                }

                persistenceRow(
                    title: AppLocalization.string("Usage History"),
                    detail: AppLocalization.string("Token counts and internal route identifiers; request and response content is not stored."),
                    url: model.runtimeProfile.tokenUsageURL,
                    directoryURL: model.runtimeProfile.applicationSupportDirectoryURL
                )

                persistenceRow(
                    title: AppLocalization.string("Subscription Data"),
                    detail: AppLocalization.string("CLIProxyAPI helper configuration and OAuth account files. This folder can contain sensitive credentials."),
                    url: model.runtimeProfile.cliProxyDataDirectoryURL,
                    directoryURL: model.runtimeProfile.cliProxyDataDirectoryURL
                )

                persistenceRow(
                    title: AppLocalization.string("App Preferences"),
                    detail: AppLocalization.string("Window and update preferences. Login launch is managed separately by macOS."),
                    url: model.runtimeProfile.preferencesURL,
                    directoryURL: model.runtimeProfile.preferencesURL.deletingLastPathComponent()
                )

                keychainRow
            }

            Section("Software Updates") {
                LabeledContent("Current Version", value: updates.currentVersion)
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updates.automaticChecksEnabled },
                    set: { updates.setAutomaticChecksEnabled($0) }
                ))
                .disabled(!updates.updatesAvailable)

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
                    .disabled(updates.isChecking || !updates.updatesAvailable)

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

    private func persistenceRow(
        title: String,
        detail: String,
        url: URL,
        directoryURL: URL
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Button {
                    model.openPersistenceDirectory(directoryURL)
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .help("Open the \(title.lowercased()) folder in Finder")
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(displayPath(url))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var keychainRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Keychain Secrets")
                Spacer()
                Button {
                    model.openKeychainAccess()
                } label: {
                    Label("Open Keychain Access", systemImage: "key")
                }
                .help("Open Keychain Access")
            }
            Text(keychainDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(keychainServices)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func displayPath(_ url: URL) -> String {
        NSString(string: url.path).abbreviatingWithTildeInPath
    }

    private var keychainDetail: String {
        guard !model.runtimeProfile.legacySecretServices.isEmpty else {
            return AppLocalization.string("API keys and management passwords are stored by macOS, not in a ModelMoor file.")
        }
        return AppLocalization.string("API keys and management passwords are stored by macOS. Legacy services are read only for upgrade compatibility.")
    }

    private var keychainServices: String {
        ([model.runtimeProfile.secretService] + model.runtimeProfile.legacySecretServices)
            .joined(separator: "\n")
    }
}

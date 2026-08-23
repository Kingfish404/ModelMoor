import AppKit
import ModelMoorApplication
import ModelMoorCore
import ModelMoorSystem
import SwiftUI

@main
struct ModelMoorApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleController.self) private var lifecycle

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(lifecycle.model)
                .environmentObject(lifecycle)
                .environmentObject(lifecycle.updates)
        } label: {
            MooringMenuIcon(phase: lifecycle.model.overallPhase)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    lifecycle.checkForUpdates()
                }
                .disabled(lifecycle.updates.isChecking || !lifecycle.updates.updatesAvailable)
            }

            CommandGroup(after: .help) {
                Button("Copy Diagnostic Summary") {
                    Task { await lifecycle.model.copyDiagnosticSummary() }
                }
            }

            CommandGroup(replacing: .sidebar) {
                Button("Show or Hide Sidebar") {
                    lifecycle.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
            }

            CommandGroup(after: .sidebar) {
                Button("Refresh Status") {
                    Task { await lifecycle.model.inspectAllEndpoints() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!canRefreshAllEndpoints)
            }

            CommandMenu("Navigate") {
                Button("Search Sidebar") {
                    lifecycle.focusSidebarSearch()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Divider()

                ForEach(MainNavigationCommand.all) { command in
                    Button {
                        lifecycle.navigate(to: command.selection)
                    } label: {
                        Text(command.localizedTitle)
                    }
                    .keyboardShortcut(command.keyEquivalent, modifiers: .command)
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    lifecycle.model.showSettings()
                    lifecycle.showMainWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("New API Endpoint…") {
                    lifecycle.showMainWindow()
                    lifecycle.model.requestAddEndpoint()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New SSH Connection…") {
                    lifecycle.showMainWindow()
                    lifecycle.model.requestAddSSHConnection()
                }

                Button(duplicateCommandTitle) {
                    lifecycle.duplicateSelectedItem()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!lifecycle.model.canDuplicateSelectedEndpoint && lifecycle.model.selectedTunnelID == nil)
            }

            CommandMenu("Connection") {
                Button("Connect Selected") {
                    guard let id = lifecycle.model.selectedTunnelID else { return }
                    Task { await lifecycle.model.connect(id) }
                }
                .disabled(selectedTunnel.map {
                    !ConnectionInteractionPolicy.canConnect(
                        $0,
                        phase: lifecycle.model.status(for: $0.id).phase
                    )
                } ?? true)

                Button("Disconnect Selected") {
                    guard let id = lifecycle.model.selectedTunnelID else { return }
                    Task { await lifecycle.model.disconnect(id) }
                }
                .disabled(selectedTunnel.map {
                    !ConnectionInteractionPolicy.canDisconnect(
                        phase: lifecycle.model.status(for: $0.id).phase
                    )
                } ?? true)

                Divider()
                Button("Connect All") { Task { await lifecycle.model.connectAll() } }
                    .disabled(!lifecycle.model.canConnectAll)
                Button("Disconnect All") { Task { await lifecycle.model.disconnectAll() } }
                    .disabled(!lifecycle.model.canDisconnectAll)
            }

            CommandMenu("Unified API") {
                Button("Show Unified API") {
                    lifecycle.model.showGateway()
                    lifecycle.showMainWindow()
                }
                Button("Copy Unified URL", action: lifecycle.model.copyGatewayURL)
                Button("Copy Unified API Key") {
                    Task { await lifecycle.model.copyGatewayToken() }
                }
                    .disabled(
                        !lifecycle.model.configuration.gateway.enabled
                            || lifecycle.model.isUpdatingGatewayAccess
                    )
            }
        }
    }

    private var duplicateCommandTitle: String {
        if lifecycle.model.canDuplicateSelectedEndpoint {
            return AppLocalization.string("Duplicate API Endpoint")
        }
        if lifecycle.model.selectedTunnelID != nil {
            return AppLocalization.string("Duplicate SSH Connection")
        }
        return AppLocalization.string("Duplicate")
    }

    private var selectedTunnel: TunnelConfiguration? {
        guard let id = lifecycle.model.selectedTunnelID else { return nil }
        return lifecycle.model.configuration.tunnels.first { $0.id == id }
    }

    private var canRefreshAllEndpoints: Bool {
        EndpointInteractionPolicy.canRefreshAll(
            endpoints: lifecycle.model.configuration.endpoints,
            inspectingEndpointIDs: lifecycle.model.inspectingEndpointIDs
        )
    }
}

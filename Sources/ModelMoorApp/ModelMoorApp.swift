import AppKit
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
                .disabled(lifecycle.updates.isChecking)
            }

            CommandGroup(replacing: .sidebar) {
                Button("Show or Hide Sidebar") {
                    lifecycle.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
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
                    if let endpointID = lifecycle.model.selectedEndpointID,
                       lifecycle.model.canDuplicateSelectedEndpoint {
                        Task { await lifecycle.model.duplicateEndpoint(endpointID) }
                    } else {
                        lifecycle.model.duplicateSelectedTunnel()
                    }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!lifecycle.model.canDuplicateSelectedEndpoint && lifecycle.model.selectedTunnelID == nil)
            }

            CommandMenu("Connection") {
                Button("Connect Selected") {
                    guard let id = lifecycle.model.selectedTunnelID else { return }
                    Task { await lifecycle.model.connect(id) }
                }
                .disabled(lifecycle.model.selectedTunnelID == nil)

                Button("Disconnect Selected") {
                    guard let id = lifecycle.model.selectedTunnelID else { return }
                    Task { await lifecycle.model.disconnect(id) }
                }
                .disabled(lifecycle.model.selectedTunnelID == nil)

                Divider()
                Button("Connect All") { Task { await lifecycle.model.connectAll() } }
                Button("Disconnect All") { Task { await lifecycle.model.disconnectAll() } }
            }

            CommandMenu("Unified API") {
                Button("Show Unified API") {
                    lifecycle.model.showGateway()
                    lifecycle.showMainWindow()
                }
                Button("Copy Unified URL", action: lifecycle.model.copyGatewayURL)
                Button("Copy Unified API Key", action: lifecycle.model.copyGatewayToken)
                    .disabled(!lifecycle.model.configuration.gateway.enabled)
            }
        }
    }

    private var duplicateCommandTitle: String {
        if lifecycle.model.canDuplicateSelectedEndpoint { return "Duplicate API Endpoint" }
        if lifecycle.model.selectedTunnelID != nil { return "Duplicate SSH Connection" }
        return "Duplicate"
    }
}

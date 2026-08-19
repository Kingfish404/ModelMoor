import AppKit
import SwiftUI

@MainActor
final class AppLifecycleController: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    let model = AppModel()

    private var mainWindowController: NSWindowController?
    private var terminationRequested = false
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.model.prepareForSleep() }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.model.resumeAfterWake() }
            }
        ]
        Task { @MainActor in
            while !model.isLoaded {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let configuration = model.configuration
            let hasUsableDirectEndpoint = configuration.endpoints.contains { endpoint in
                guard case .directHTTPS = endpoint.source else { return false }
                return endpoint.authentication == .none || model.hasToken(for: endpoint.id)
            }
            if configuration.tunnels.isEmpty,
               configuration.routes.isEmpty,
               !configuration.gateway.enabled,
               !hasUsableDirectEndpoint {
                showMainWindow()
            }
        }
    }

    func showMainWindow() {
        model.setUIRefreshActive(true)
        NSApplication.shared.setActivationPolicy(.regular)
        let controller = mainWindowController ?? makeMainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindowController?.window else { return }
        DispatchQueue.main.async {
            guard self.mainWindowController?.window?.isVisible != true else { return }
            self.model.setUIRefreshActive(false)
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateNow }
        terminationRequested = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func toggleSidebar() {
        NSApplication.shared.sendAction(
            #selector(NSSplitViewController.toggleSidebar(_:)),
            to: nil,
            from: nil
        )
    }

    private func makeMainWindowController() -> NSWindowController {
        let rootView = MainWindowView()
            .environmentObject(model)
            .environmentObject(self)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "ModelMoor"
        window.setContentSize(NSSize(width: 1_020, height: 720))
        window.minSize = NSSize(width: 860, height: 600)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarSeparatorStyle = .line
        window.toolbarStyle = .unified
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = true
        window.delegate = self
        window.setFrameAutosaveName("ModelMoorMainWindow")
        window.center()
        return NSWindowController(window: window)
    }
}

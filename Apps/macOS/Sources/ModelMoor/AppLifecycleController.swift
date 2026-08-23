import AppKit
import ModelMoorCore
import ModelMoorSystem
import SwiftUI

@MainActor
final class AppLifecycleController: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    let runtimeProfile: ModelMoorRuntimeProfile
    let model: AppModel
    let updates: UpdateController
    let dirtyDrafts = DirtyDraftCoordinator()
    let sidebarSearchFocus = SidebarSearchFocusCoordinator()

    private var mainWindowController: NSWindowController?
    private var terminationRequested = false
    private var terminationApproved = false
    private lazy var windowCloseCoordinator = DirtyWindowCloseCoordinator(dirtyDrafts: dirtyDrafts)
    private var workspaceObservers: [NSObjectProtocol] = []

    override init() {
        let profile = ModelMoorRuntimeProfile.current
        runtimeProfile = profile
        model = AppModel(runtimeProfile: profile)
        updates = UpdateController(updatesAvailable: profile.supportsSoftwareUpdates)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        updates.start()
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
                switch endpoint.source {
                case .directHTTPS, .managedCLIProxy: break
                case .sshMapping: return false
                }
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
        NSApplication.shared.setActivationPolicy(.regular)
        let controller = mainWindowController ?? makeMainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        updateUIRefreshActivity(applicationIsActive: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        updateUIRefreshActivity(applicationIsActive: true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        updateUIRefreshActivity(applicationIsActive: false)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindowController?.window else { return }
        DispatchQueue.main.async {
            guard self.mainWindowController?.window?.isVisible != true else { return }
            self.updateUIRefreshActivity(applicationIsActive: false)
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        updateUIRefreshActivity()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updateUIRefreshActivity()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindowController?.window else { return true }
        return windowCloseCoordinator.shouldClose(sender)
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
        if !terminationApproved, dirtyDrafts.hasUnsavedChanges {
            // A menu-bar quit can arrive while the app is hidden. Bring the
            // editor back so the save decision is never stranded off-screen.
            showMainWindow()
            dirtyDrafts.requestTransition { [weak self, weak sender] in
                guard let self, let sender else { return }
                self.terminationApproved = true
                sender.terminate(nil)
            }
            return .terminateCancel
        }
        terminationRequested = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        updates.stop()
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Commands that create and select another item must resolve the visible
    /// draft before mutating configuration, just like sidebar navigation.
    func duplicateSelectedItem() {
        dirtyDrafts.requestTransition { [weak self] in
            guard let self else { return }
            if let endpointID = model.selectedEndpointID,
               model.canDuplicateSelectedEndpoint {
                Task { await model.duplicateEndpoint(endpointID) }
            } else if model.selectedTunnelID != nil {
                Task { await model.duplicateSelectedTunnel() }
            }
        }
    }

    func toggleSidebar() {
        NSApplication.shared.sendAction(
            #selector(NSSplitViewController.toggleSidebar(_:)),
            to: nil,
            from: nil
        )
    }

    func focusSidebarSearch() {
        sidebarSearchFocus.requestFocus()
        showMainWindow()
    }

    func navigate(to selection: NavigationSelection) {
        showMainWindow()
        model.navigationRequest = selection
    }

    func checkForUpdates() {
        guard !updates.isChecking else { return }
        Task {
            let outcome = await updates.checkNow()
            presentUpdateResult(outcome)
        }
    }

    private func updateUIRefreshActivity(applicationIsActive: Bool? = nil) {
        let window = mainWindowController?.window
        model.setUIRefreshActive(PresentationRefreshPolicy.shouldRefreshUsage(
            windowIsVisible: window?.isVisible == true,
            windowIsMiniaturized: window?.isMiniaturized == true,
            applicationIsActive: applicationIsActive ?? NSApplication.shared.isActive
        ))
    }

    private func makeMainWindowController() -> NSWindowController {
        let rootView = MainWindowView()
            .environmentObject(model)
            .environmentObject(self)
            .environmentObject(updates)
            .environmentObject(dirtyDrafts)
            .environmentObject(sidebarSearchFocus)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = runtimeProfile.displayName
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
        window.setFrameAutosaveName("\(runtimeProfile.displayName.replacingOccurrences(of: " ", with: ""))MainWindow")
        window.center()
        return NSWindowController(window: window)
    }

    private func presentUpdateResult(_ outcome: UpdateController.CheckOutcome) {
        if case .alreadyChecking = outcome { return }

        let alert = NSAlert()
        switch outcome {
        case let .updateAvailable(release):
            alert.messageText = AppLocalization.string("A New Version Is Available")
            alert.informativeText = AppLocalization.format(
                "ModelMoor %@ is available. You are currently using version %@.",
                release.tagName,
                updates.currentVersion
            )
            alert.addButton(withTitle: AppLocalization.string(
                release.downloadURL == nil ? "View Release" : "Download Update"
            ))
            alert.addButton(withTitle: AppLocalization.string("Not Now"))
            NSApplication.shared.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                updates.download(release)
            }
        case .upToDate:
            alert.messageText = AppLocalization.string("ModelMoor Is Up to Date")
            alert.informativeText = AppLocalization.format(
                "Version %@ is the newest version available.",
                updates.currentVersion
            )
            alert.addButton(withTitle: AppLocalization.string("OK"))
            NSApplication.shared.activate(ignoringOtherApps: true)
            alert.runModal()
        case let .failed(message):
            alert.alertStyle = .warning
            alert.messageText = AppLocalization.string("Couldn’t Check for Updates")
            alert.informativeText = message
            alert.addButton(withTitle: AppLocalization.string("OK"))
            NSApplication.shared.activate(ignoringOtherApps: true)
            alert.runModal()
        case .alreadyChecking:
            break
        }
    }
}

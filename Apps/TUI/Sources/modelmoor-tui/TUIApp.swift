import Foundation
import TermKit
import TUIWidgets
import ModelMoorApplication
import ModelMoorCore
import ModelMoorGateway
import ModelMoorSystem

/// TermKit front end for `ModelMoorSession`. Renders snapshots; every state
/// change goes through session commands. The settings pane uses the same
/// session transactions as the GUI and CLI, while runtime ownership remains
/// explicit and exclusive across GUI, CLI and TUI.
final class TUIApp: @unchecked Sendable {
    // Synchronization invariant: TermKit views, selection indexes and rendered
    // snapshots are accessed only on DispatchQueue.main. Async work reaches
    // those values through MainActorless. Lifecycle/task handles and runtime
    // ownership cross executors and are therefore protected by lifecycleLock.
    private let session: ModelMoorSession
    private let glyphs: TUIGlyphSet
    private let lifecycleLock = NSLock()
    private var ownsRuntime = false
    private var quitting = false
    private var refreshCoalescer = TUIRefreshCoalescer()
    private var snapshotTask: Task<Void, Never>?
    private var usageTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var attentionRenderID = UUID()
    private var attentionBaseText = ""
    private var selectedPaneIndex = TUIPane.overview.rawValue
    private var listFilters: [TUIPane: PresentationSearchQuery] = [:]

    // Views
    private var window: KeyHandlingWindow!
    private var summaryLabel: Label!
    private var statusBar: StatusBar!
    private var tabView: TabView!
    private var helpPageText: TextView!
    private var overviewText: TextView!
    private var tunnelsList: ListView!
    private var endpointsList: ListView!
    private var gatewayText: TextView!
    private var routesList: ListView!
    private var subscriptionsText: TextView!
    private var attentionText: TextView!
    private var settingsText: TextView!
    private var shellFeedback: Label!
    private var shellPrompt: Label!
    private var shellInput: ShellTextField!

    private var currentSnapshot = AppSnapshot()
    private var listedTunnelIDs: [UUID] = []
    private var listedEndpointIDs: [UUID] = []
    private var listedRouteIDs: [UUID] = []
    private var tunnelSelection = TUISelectionMemory<UUID>()
    private var endpointSelection = TUISelectionMemory<UUID>()
    private var routeSelection = TUISelectionMemory<UUID>()
    private var observedTunnelSelectionIndex: Int?
    private var observedEndpointSelectionIndex: Int?
    private var observedRouteSelectionIndex: Int?
    private var tunnelsByID: [UUID: TunnelConfiguration] = [:]
    private var tunnelSearchDocuments = TUISearchDocumentCache<[TunnelConfiguration]>()
    private var endpointSearchDocuments = TUISearchDocumentCache<EndpointSearchSource>()
    private var routeSearchDocuments = TUISearchDocumentCache<RouteSearchSource>()

    init(session: ModelMoorSession, glyphs: TUIGlyphSet = .preferred()) {
        self.session = session
        self.glyphs = glyphs
    }

    private var runtimeIsOwned: Bool {
        lifecycleLock.withLock { ownsRuntime }
    }

    private var isQuitting: Bool {
        lifecycleLock.withLock { quitting }
    }

    // MARK: - Setup

    func setup() {
        Application.prepare()
        TUITheme.apply(to: Application.top)

        let top = Application.top
        window = KeyHandlingWindow("ModelMoor", usesASCIIBorder: glyphs.usesASCII)
        TUITheme.apply(to: window)
        window.globalKeyHandler = { [weak self] event in
            self?.handleGlobalKey(event) ?? false
        }
        window.interactionDidFinish = { [weak self] in
            self?.synchronizeInteractionState()
        }
        window.x = Pos.at(0)
        window.y = Pos.at(0)
        window.width = Dim.fill()
        window.height = Dim.fill()
        top.addSubview(window)

        summaryLabel = Label("")
        summaryLabel.x = Pos.at(1)
        summaryLabel.y = Pos.at(0)
        summaryLabel.width = Dim.fill(1)
        summaryLabel.height = Dim.sized(1)
        window.addSubview(summaryLabel)

        tabView = TabView()
        if glyphs.usesASCII {
            tabView.tabStyle = .plain
        }
        tabView.x = Pos.at(0)
        tabView.y = Pos.top(of: summaryLabel) + 1
        tabView.width = Dim.fill()
        tabView.height = Dim.fill(3)  // leave room for feedback, shell, and status bar
        window.addSubview(tabView)

        buildHelpTab()
        buildOverviewTab()
        buildGatewayTab()
        buildTunnelsTab()
        buildEndpointsTab()
        buildSubscriptionsTab()
        buildAttentionTab()
        buildSettingsTab()

        shellFeedback = Label("SHELL ACTIVE: type help and press Enter")
        shellFeedback.x = Pos.at(1)
        shellFeedback.y = Pos.anchorEnd(margin: 2)
        shellFeedback.width = Dim.fill(1)
        shellFeedback.height = Dim.sized(1)
        TUITheme.apply(to: shellFeedback)
        window.addSubview(shellFeedback)

        shellPrompt = Label("moor>")
        shellPrompt.x = Pos.at(1)
        shellPrompt.y = Pos.anchorEnd(margin: 1)
        shellPrompt.width = Dim.sized(5)
        shellPrompt.height = Dim.sized(1)
        TUITheme.apply(to: shellPrompt)
        window.addSubview(shellPrompt)

        shellInput = ShellTextField()
        shellInput.x = Pos.at(7)
        shellInput.y = Pos.anchorEnd(margin: 1)
        shellInput.width = Dim.fill(1)
        shellInput.height = Dim.sized(1)
        TUITheme.apply(to: shellInput)
        shellInput.onSubmit = { [weak self] _ in self?.submitShellCommand() }
        window.addSubview(shellInput)

        statusBar = StatusBar()
        statusBar.colorScheme = TUITheme.dialog
        statusBar.x = Pos.at(0)
        statusBar.y = Pos.anchorEnd()
        statusBar.width = Dim.fill()
        statusBar.height = Dim.sized(1)
        window.addSubview(statusBar)
        statusBar.addHotkeyPanel(
            id: "quit",
            hotkeyText: "q",
            labelText: "quit",
            hotkey: .letter("q"),
            action: { [weak self] in self?.requestQuit() },
            priority: .veryHigh
        )
        statusBar.addHotkeyPanel(
            id: "refresh",
            hotkeyText: "r",
            labelText: "refresh",
            hotkey: .letter("r"),
            action: { [weak self] in
                Task { @Sendable [weak self] in
                    await self?.requestRefresh()
                }
            },
            priority: .default
        )
        statusBar.addHotkeyPanel(
            id: "help",
            hotkeyText: "?",
            labelText: "help",
            hotkey: .letter("?"),
            action: { [weak self] in self?.openHelpPane() },
            priority: .low
        )
        statusBar.addPanel(
            id: "pane",
            content: TUIPane.overview.title,
            priority: .high,
            placement: .leading
        )
        statusBar.addPanel(id: "panes", content: "\(glyphs.paneRange) panes", priority: .veryLow)
        statusBar.addPanel(id: "shell", content: ": shell", priority: .low)

        updateContextualHotkeys(for: .overview)

        render(AppSnapshot(), force: true)
        focusShell(message: "SHELL ACTIVE: type help and press Enter")
    }

    private func buildHelpTab() {
        helpPageText = makeCopyableTextView()
        helpPageText.text = TUIInteractionModel.helpPageText(ascii: glyphs.usesASCII)
        tabView.addTab(TUIPane.help.tabTitle, content: helpPageText)
    }

    private func buildOverviewTab() {
        overviewText = makeCopyableTextView()
        tabView.addTab(TUIPane.overview.tabTitle, content: overviewText)
    }

    private func buildTunnelsTab() {
        tunnelsList = ListView(items: [])
        tabView.addTab(TUIPane.sshConnections.tabTitle, content: tunnelsList)
    }

    private func buildEndpointsTab() {
        endpointsList = ListView(items: [])
        tabView.addTab(TUIPane.apiEndpoints.tabTitle, content: endpointsList)
    }

    private func buildGatewayTab() {
        let container = View()
        container.fill()
        gatewayText = makeCopyableTextView()
        gatewayText.width = Dim.fill()
        gatewayText.height = Dim.sized(4)
        container.addSubview(gatewayText)

        routesList = ListView(items: [])
        routesList.y = Pos.bottom(of: gatewayText)
        routesList.width = Dim.fill()
        routesList.height = Dim.fill()
        container.addSubview(routesList)
        tabView.addTab(TUIPane.unifiedAPI.tabTitle, content: container)
    }

    private func buildSubscriptionsTab() {
        subscriptionsText = makeCopyableTextView()
        tabView.addTab(TUIPane.subscriptions.tabTitle, content: subscriptionsText)
    }

    private func buildAttentionTab() {
        attentionText = makeCopyableTextView()
        tabView.addTab(TUIPane.needsAttention.tabTitle, content: attentionText)
    }

    private func buildSettingsTab() {
        settingsText = makeCopyableTextView()
        tabView.addTab(TUIPane.settings.tabTitle, content: settingsText)
    }

    private func makeCopyableTextView() -> CopyableTextView {
        let text = CopyableTextView()
        text.isReadOnly = true
        text.onCopy = { [weak self] value in
            self?.writeClipboard(value, successMessage: "Text copied to clipboard")
        }
        return text
    }

    // MARK: - Lifecycle

    /// Loads configuration and starts the snapshot subscription. Called from a
    /// background task; never blocks the main queue.
    func start() async {
        do {
            try await session.load()
            await session.refreshRuntimeState()
        } catch {
            await MainActorless.showError(self, message: error.localizedDescription)
        }
        let newSnapshotTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in session.snapshots() {
                await MainActorless.render(self, snapshot: snapshot)
                if Task.isCancelled { break }
            }
        }
        let keepsSnapshotTask = lifecycleLock.withLock { () -> Bool in
            guard !quitting else { return false }
            snapshotTask = newSnapshotTask
            return true
        }
        guard keepsSnapshotTask else {
            newSnapshotTask.cancel()
            return
        }
        await requestRefresh(reloadConfiguration: false)
        await MainActorless.activateVisibleWork(self)
    }

    func requestQuit() {
        let state = lifecycleLock.withLock { () -> (Bool, [Task<Void, Never>])? in
            guard !quitting else { return nil }
            quitting = true
            let tasks = [snapshotTask, usageTask, diagnosticsTask].compactMap { $0 }
            snapshotTask = nil
            usageTask = nil
            diagnosticsTask = nil
            refreshCoalescer.cancel()
            return (ownsRuntime, tasks)
        }
        guard let (shouldStopRuntime, tasks) = state else { return }
        tasks.forEach { $0.cancel() }
        Task.detached { [weak self] in
            guard let self else {
                MainActorless.requestStop()
                return
            }
            if shouldStopRuntime {
                await session.stopRuntime()
            }
            MainActorless.requestStop()
        }
    }

    // MARK: - Commands

    func requestRefresh(reloadConfiguration: Bool = true) async {
        let decision = lifecycleLock.withLock { () -> TUIRefreshRequestDecision in
            guard !quitting else { return .ignored }
            return refreshCoalescer.request(reloadConfiguration: reloadConfiguration)
        }

        let initialReloadConfiguration: Bool
        switch decision {
        case let .start(reloadConfiguration):
            initialReloadConfiguration = reloadConfiguration
        case .queued:
            showStatusAsync("Refresh queued")
            return
        case .alreadyQueued:
            showStatusAsync("Refresh already queued")
            return
        case .ignored:
            return
        }

        synchronizeRefreshIndicatorAsync()
        var shouldReloadConfiguration = initialReloadConfiguration
        var finalCycleSucceeded = false
        while !Task.isCancelled && !isQuitting {
            let inspectEndpoints = await MainActorless.shouldInspectEndpoints(self)
            finalCycleSucceeded = await performRefresh(
                reloadConfiguration: shouldReloadConfiguration,
                inspectEndpoints: inspectEndpoints
            )
            let completion = lifecycleLock.withLock {
                refreshCoalescer.completeCycle()
            }
            switch completion {
            case let .continueRefresh(reloadConfiguration):
                shouldReloadConfiguration = reloadConfiguration
            case .finish:
                synchronizeRefreshIndicatorAsync()
                if finalCycleSucceeded { showStatusAsync("Status refreshed") }
                return
            }
        }
        lifecycleLock.withLock { refreshCoalescer.cancel() }
        synchronizeRefreshIndicatorAsync()
    }

    private func performRefresh(
        reloadConfiguration: Bool,
        inspectEndpoints: Bool
    ) async -> Bool {
        do {
            // Reload external CLI/GUI edits while this TUI is not editing a
            // form. Once this TUI owns the runtime, keep its requested tunnel
            // set stable: load() resets that set to connect-on-launch defaults.
            if reloadConfiguration && !runtimeIsOwned {
                try await session.load()
            }
            await session.refreshRuntimeState()
            if inspectEndpoints {
                await session.inspectAllEndpoints()
            }
            return true
        } catch {
            showErrorAsync(error.localizedDescription)
            return false
        }
    }

    private func handleGlobalKey(_ event: KeyEvent) -> Bool {
        switch event.key {
        case .controlC:
            if hasFocusedCopyableTextView { return false }
            if copyFocusedListRow() { return true }
            requestQuit()
            return true
        case let .letter(character):
            if shellInput?.hasFocus == true { return false }
            if character == ":" {
                focusShell()
                return true
            }
            guard let pane = TUIPane.matching(shortcut: character) else { return false }
            tabView.selectedTab = pane.rawValue
            return true
        case .f1:
            openHelpPane()
            return true
        default:
            return false
        }
    }

    private var hasFocusedCopyableTextView: Bool {
        [helpPageText, overviewText, gatewayText, subscriptionsText, attentionText, settingsText]
            .contains { $0?.hasFocus == true }
    }

    private func copyFocusedListRow() -> Bool {
        for list in [tunnelsList, endpointsList, routesList] where list?.hasFocus == true {
            guard let list,
                  let items = list.items,
                  items.indices.contains(list.selectedItem) else {
                return false
            }
            writeClipboard(items[list.selectedItem], successMessage: "Selected row copied to clipboard")
            return true
        }
        return false
    }

    fileprivate func shouldInspectEndpoints() -> Bool {
        guard let pane = TUIPane(rawValue: selectedPaneIndex) else { return false }
        return TUIVisibilityWorkPolicy.shouldInspectEndpoints(selectedPane: pane)
    }

    private func submitShellCommand() {
        let input = shellInput.text.trimmingCharacters(in: .whitespacesAndNewlines)
        shellInput.text = ""
        guard let command = TUIShellParser.parse(input) else {
            focusShell(message: "SHELL: enter a command, or type help")
            return
        }
        shellFeedback.text = "RUN: " + input
        shellFeedback.setNeedsDisplay()
        Application.refresh()
        executeShellCommand(command)
    }

    private func executeShellCommand(_ command: TUIShellCommand) {
        switch command {
        case .help:
            openHelpPane()
        case .status:
            let configuration = currentSnapshot.configuration
            let gateway = configuration.gateway.enabled ? "on" : "off"
            showStatus(
                "SSH \(configuration.tunnels.count) | API \(configuration.endpoints.count) | "
                    + "subscriptions \(currentSnapshot.subscriptions.accounts.count) | "
                    + "gateway \(gateway)"
            )
        case .refresh:
            Task { [weak self] in await self?.requestRefresh() }
        case .list:
            tabView.selectedTab = TUIPane.settings.rawValue
            showStatus("Settings pane selected")
        case let .filter(query):
            applyShellFilter(query)
        case .clearFilter:
            clearShellFilter()
        case .addSSH:
            showSSHForm()
        case .addPort:
            showPortForm()
        case .addAPI:
            showAPIForm()
        case .subscriptions:
            showSubscriptionForm()
        case let .subscriptionLogin(provider):
            startSubscriptionLogin(providerName: provider)
        case .subscriptionAccounts:
            showSubscriptionAccounts()
        case .subscriptionRefresh:
            refreshSubscriptionAccounts()
        case .subscriptionCancel:
            cancelSubscriptionLogin()
        case .gateway:
            showGatewayForm()
        case let .connect(name):
            setTunnelConnection(name: name, connected: true)
        case let .disconnect(name):
            setTunnelConnection(name: name, connected: false)
        case .clear:
            showStatus("Shell ready")
        case .quit:
            requestQuit()
        case let .unknown(input):
            showError("Unknown shell command: " + input + ". Type help for commands.")
        }
    }

    private func setTunnelConnection(name: String?, connected: Bool) {
        let tunnel: TunnelConfiguration?
        if let name {
            tunnel = currentSnapshot.configuration.tunnels.first {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }
            guard tunnel != nil else {
                showError("SSH connection not found: " + name)
                return
            }
        } else {
            tunnel = selectedTunnel()
            guard tunnel != nil else {
                showError("Select an SSH connection first, or use connect <name>.")
                return
            }
        }
        guard let tunnel else { return }
        let tunnelID = tunnel.id
        Task { [weak self] in
            guard let self else { return }
            do {
                if connected {
                    try await ensureRuntimeOwnership()
                    try await session.connectTunnel(tunnelID)
                    showStatusAsync("Connected " + tunnel.name)
                } else {
                    await session.disconnectTunnel(tunnelID)
                    showStatusAsync("Disconnected " + tunnel.name)
                }
            } catch {
                showErrorAsync(error.localizedDescription)
            }
        }
    }

    private func synchronizePaneSelection() {
        let index = tabView.selectedTab
        guard index != selectedPaneIndex, let pane = TUIPane(rawValue: index) else { return }
        selectedPaneIndex = index
        updateContextualHotkeys(for: pane)
        updatePaneStatus()
        updateUsageRefresh(for: pane, refreshImmediately: true)
        if TUIVisibilityWorkPolicy.shouldInspectEndpoints(selectedPane: pane) {
            Task { [weak self] in
                await self?.requestRefresh(reloadConfiguration: false)
            }
        }
        if TUIVisibilityWorkPolicy.shouldLoadDiagnostics(selectedPane: pane) {
            refreshAttentionDiagnostics()
        } else {
            cancelAttentionDiagnostics()
        }
    }

    /// Called only after real keyboard or mouse input. Programmatic row
    /// restoration during a snapshot render deliberately does not pass here,
    /// so a filter fallback cannot silently replace the user's preferred ID.
    private func synchronizeInteractionState() {
        synchronizePaneSelection()
        guard let pane = TUIPane(rawValue: selectedPaneIndex) else { return }
        switch pane {
        case .sshConnections:
            let index = tunnelsList.selectedItem
            if index != observedTunnelSelectionIndex {
                tunnelSelection.recordVisibleSelection(index: index, visibleIDs: listedTunnelIDs)
            }
            observedTunnelSelectionIndex = listedTunnelIDs.isEmpty ? nil : index
        case .apiEndpoints:
            let index = endpointsList.selectedItem
            if index != observedEndpointSelectionIndex {
                endpointSelection.recordVisibleSelection(index: index, visibleIDs: listedEndpointIDs)
            }
            observedEndpointSelectionIndex = listedEndpointIDs.isEmpty ? nil : index
        case .unifiedAPI:
            let index = routesList.selectedItem
            if index != observedRouteSelectionIndex {
                routeSelection.recordVisibleSelection(index: index, visibleIDs: listedRouteIDs)
            }
            observedRouteSelectionIndex = listedRouteIDs.isEmpty ? nil : index
        case .help, .overview, .subscriptions, .needsAttention, .settings:
            break
        }
        updateContextualHotkeys(for: pane)
    }

    /// The usage report appears only on Overview. Keep its periodic disk read
    /// alive exactly while that pane is visible, and refresh immediately when
    /// the user returns after spending time elsewhere.
    fileprivate func activateVisibleWork() {
        guard let pane = TUIPane(rawValue: selectedPaneIndex) else { return }
        // load() already refreshed usage during startup.
        updateUsageRefresh(for: pane, refreshImmediately: false)
    }

    private func updateUsageRefresh(for pane: TUIPane, refreshImmediately: Bool) {
        if TUIVisibilityWorkPolicy.shouldRefreshUsage(selectedPane: pane) {
            startUsageRefresh(refreshImmediately: refreshImmediately)
        } else {
            stopUsageRefresh()
        }
    }

    private func startUsageRefresh(refreshImmediately: Bool) {
        let shouldStart = lifecycleLock.withLock { !quitting && usageTask == nil }
        guard shouldStart else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            if refreshImmediately {
                await session.refreshUsage()
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await session.refreshUsage()
            }
        }
        let keepsTask = lifecycleLock.withLock { () -> Bool in
            guard !quitting, usageTask == nil else { return false }
            usageTask = task
            return true
        }
        if !keepsTask { task.cancel() }
    }

    private func stopUsageRefresh() {
        let task = lifecycleLock.withLock { () -> Task<Void, Never>? in
            let task = usageTask
            usageTask = nil
            return task
        }
        task?.cancel()
    }

    private func updateContextualHotkeys(for pane: TUIPane, refresh: Bool = true) {
        for id in ["filter", "clear-filter", "connect", "retry", "copy-url", "copy-model", "add-ssh", "add-api", "subscriptions", "gateway"] {
            statusBar.removePanel(id: id)
        }
        statusBar.setNeedsDisplay()
        if refresh {
            Application.refresh()
        }
    }

    private func applyShellFilter(_ text: String) {
        guard let pane = TUIPane(rawValue: selectedPaneIndex),
              pane == .sshConnections || pane == .apiEndpoints || pane == .unifiedAPI else {
            showError("Filter is available in SSH Connections, API Endpoints, and Unified API.")
            return
        }
        applyFilter(PresentationSearchQuery(text), to: pane)
        showStatus("Filter applied")
    }

    private func clearShellFilter() {
        guard let pane = TUIPane(rawValue: selectedPaneIndex),
              pane == .sshConnections || pane == .apiEndpoints || pane == .unifiedAPI else {
            showError("No list filter is active in this pane.")
            return
        }
        applyFilter(PresentationSearchQuery(""), to: pane)
        showStatus("Filter cleared")
    }

    private func applyFilter(_ query: PresentationSearchQuery, to pane: TUIPane) {
        if query.isEmpty {
            listFilters[pane] = nil
        } else {
            listFilters[pane] = query
        }
        switch pane {
        case .sshConnections:
            renderTunnels(currentSnapshot)
        case .apiEndpoints:
            renderEndpoints(currentSnapshot)
        case .unifiedAPI:
            renderGateway(currentSnapshot)
        case .help, .overview, .subscriptions, .needsAttention, .settings:
            return
        }
        updateContextualHotkeys(for: pane)
        updatePaneStatus()
        tabView.setNeedsDisplay()
        Application.refresh()
    }

    private func updatePaneStatus() {
        guard let pane = TUIPane(rawValue: selectedPaneIndex) else { return }
        let total: Int
        let visible: Int
        switch pane {
        case .sshConnections:
            total = currentSnapshot.configuration.tunnels.count
            visible = listedTunnelIDs.count
        case .apiEndpoints:
            total = currentSnapshot.configuration.endpoints.count
            visible = listedEndpointIDs.count
        case .unifiedAPI:
            total = currentSnapshot.configuration.routes.count
            visible = listedRouteIDs.count
        case .help, .overview, .subscriptions, .needsAttention, .settings:
            statusBar.updatePanel(id: "pane", content: pane.title)
            return
        }
        if let query = listFilters[pane], !query.isEmpty {
            statusBar.updatePanel(
                id: "pane",
                content: "\(pane.title)\(glyphs.separator)\(visible)/\(total)\(glyphs.separator)\(String(query.normalizedText.prefix(24)))"
            )
        } else {
            statusBar.updatePanel(id: "pane", content: "\(pane.title)\(glyphs.separator)\(total)")
        }
    }

    private func openHelpPane() {
        tabView.selectedTab = TUIPane.help.rawValue
        showStatus("Help pane selected")
    }

    private func ensureRuntimeOwnership() async throws {
        if !runtimeIsOwned {
            try await session.startRuntime(owner: "modelmoor-tui")
            lifecycleLock.withLock { ownsRuntime = true }
        }
    }

    // MARK: - Settings

    private func showSSHForm() {
        TUIFormDialog.request(
            "Add SSH connection",
            message: "Use an SSH config alias or a user@host target. The key is stored by your SSH client.",
            fields: [
                TUIFormField("Name", "New SSH connection"),
                TUIFormField("SSH target", "user@host"),
                TUIFormField("Local port", "18888"),
                TUIFormField("Remote host", "127.0.0.1"),
                TUIFormField("Remote port", "8888"),
                TUIFormField("Connect on launch", "yes")
            ]
        ) { [weak self] values in
            guard let self, let values, values.count == 6 else { return }
            let name = values[0].trimmed
            let sshTarget = values[1].trimmed
            guard let localPort = Int(values[2].trimmed),
                  let remotePort = Int(values[4].trimmed),
                  !name.isEmpty,
                  !sshTarget.isEmpty else {
                self.showError("Name, SSH target, and valid ports are required.")
                return
            }
            let mapping = PortMappingConfiguration(
                name: "LLM API",
                listenPort: localPort,
                destinationHost: values[3].trimmed,
                destinationPort: remotePort
            )
            let tunnel = TunnelConfiguration(
                name: name,
                sshHost: sshTarget,
                mappings: [mapping],
                connectOnLaunch: values[5].isTruthy
            )
            var candidate = self.currentSnapshot.configuration
            candidate.tunnels.append(tunnel)
            Task { [weak self] in
                do {
                    try await self?.session.saveConfiguration(candidate)
                    self?.showStatusAsync("SSH connection saved")
                } catch {
                    self?.showErrorAsync(error.localizedDescription)
                }
            }
        }
    }

    private func showPortForm() {
        guard !currentSnapshot.configuration.tunnels.isEmpty else {
            showError("Add an SSH connection before adding a port mapping.")
            return
        }
        let defaultTunnel = currentSnapshot.configuration.tunnels.first?.name ?? ""
        TUIFormDialog.request(
            "Add port mapping",
            message: "The local listener is loopback-only and belongs to an existing SSH connection.",
            fields: [
                TUIFormField("SSH connection", defaultTunnel),
                TUIFormField("Mapping name", "LLM API"),
                TUIFormField("Local port", "18888"),
                TUIFormField("Remote host", "127.0.0.1"),
                TUIFormField("Remote port", "8888")
            ]
        ) { [weak self] values in
            guard let self, let values, values.count == 5,
                  let localPort = Int(values[2].trimmed),
                  let remotePort = Int(values[4].trimmed) else {
                self?.showError("Enter an SSH connection and valid local and remote ports.")
                return
            }
            let tunnelName = values[0].trimmed
            guard let index = self.currentSnapshot.configuration.tunnels.firstIndex(where: {
                $0.name.localizedCaseInsensitiveCompare(tunnelName) == .orderedSame
            }) else {
                self.showError("SSH connection not found: " + tunnelName)
                return
            }
            let mapping = PortMappingConfiguration(
                name: values[1].trimmed,
                listenPort: localPort,
                destinationHost: values[3].trimmed,
                destinationPort: remotePort
            )
            var candidate = self.currentSnapshot.configuration
            candidate.tunnels[index].mappings.append(mapping)
            Task { [weak self] in
                do {
                    try await self?.session.saveConfiguration(candidate)
                    self?.showStatusAsync("Port mapping saved")
                } catch {
                    self?.showErrorAsync(error.localizedDescription)
                }
            }
        }
    }

    private func showAPIForm() {
        TUIFormDialog.request(
            "Add API endpoint",
            message: "Direct endpoints must use an HTTPS origin, for example https://api.example.com.",
            fields: [
                TUIFormField("Name", "New API endpoint"),
                TUIFormField("HTTPS origin", "https://api.example.com"),
                TUIFormField("Base path", "/v1"),
                TUIFormField("API key", isSecret: true)
            ]
        ) { [weak self] values in
            guard let self, let values, values.count == 4 else { return }
            let name = values[0].trimmed
            let originText = values[1].trimmed
            let basePath = values[2].trimmed
            let secret = values[3].trimmed
            guard !name.isEmpty,
                  let origin = URL(string: originText),
                  !secret.isEmpty || basePath.isEmpty == false else {
                self.showError("Name, HTTPS origin, and base path are required.")
                return
            }
            let endpointID = UUID()
            let authentication: APIEndpointAuthentication = secret.isEmpty ? .none : .bearer
            let endpoint = APIEndpointConfiguration(
                id: endpointID,
                name: name,
                source: .directHTTPS(originURL: origin),
                basePath: basePath,
                healthPath: joinAPIPath(basePath, "models"),
                modelListPath: joinAPIPath(basePath, "models"),
                authentication: authentication
            )
            Task { [weak self] in
                do {
                    try await self?.session.addEndpoint(endpoint, secret: secret.isEmpty ? nil : secret)
                    self?.showStatusAsync("API endpoint saved")
                } catch {
                    self?.showErrorAsync(error.localizedDescription)
                }
            }
        }
    }

    private func showGatewayForm() {
        let gateway = currentSnapshot.configuration.gateway
        TUIFormDialog.request(
            "Configure Unified API",
            message: "The listener binds to loopback. API keys are generated and stored in the system keychain.",
            fields: [
                TUIFormField("Enabled", gateway.enabled ? "yes" : "no"),
                TUIFormField("Listen port", String(gateway.listenPort)),
                TUIFormField("Require API key", gateway.requiresAPIKey ? "yes" : "no")
            ]
        ) { [weak self] values in
            guard let values, values.count == 3,
                  let port = Int(values[1].trimmed) else {
                self?.showError("A valid Unified API port is required.")
                return
            }
            guard let self else { return }
            var candidate = self.currentSnapshot.configuration
            candidate.gateway.enabled = values[0].isTruthy
            candidate.gateway.listenPort = port
            candidate.gateway.requiresAPIKey = values[2].isTruthy
            Task { [weak self] in
                do {
                    try await self?.session.saveConfiguration(candidate)
                    if candidate.gateway.requiresAPIKey {
                        try await self?.session.ensureGatewayAPIKey()
                    }
                    self?.showStatusAsync("Unified API settings saved")
                } catch {
                    self?.showErrorAsync(error.localizedDescription)
                }
            }
        }
    }

    private func showSubscriptionForm() {
        let providers = CLIProxyLoginProvider.allCases
            .enumerated()
            .map { "\($0.offset + 1): \($0.element.displayName)" }
            .joined(separator: "  ")
        TUIFormDialog.request(
            "Connect subscription",
            message: "Choose a provider. The sign-in page opens outside ModelMoor. \(providers)",
            fields: [
                TUIFormField("Provider number", "1"),
                TUIFormField("Proxy port", String(currentSnapshot.configuration.cliProxy.listenPort))
            ]
        ) { [weak self] values in
            guard let values, values.count == 2,
                  let raw = values.first?.trimmed,
                  let index = Int(raw),
                  CLIProxyLoginProvider.allCases.indices.contains(index - 1),
                  let port = Int(values[1].trimmed) else {
                self?.showError("Choose a provider number from 1 to \(CLIProxyLoginProvider.allCases.count) and enter a valid proxy port.")
                return
            }
            guard let self else { return }
            let provider = CLIProxyLoginProvider.allCases[index - 1]
            self.beginSubscriptionLogin(provider: provider, proxyPort: port)
        }
    }

    private func startSubscriptionLogin(providerName: String?) {
        guard let providerName, !providerName.trimmed.isEmpty else {
            showSubscriptionForm()
            return
        }
        guard let provider = subscriptionProvider(named: providerName) else {
            let supported = CLIProxyLoginProvider.allCases.map(\.rawValue).joined(separator: ", ")
            showError("Unknown subscription provider: " + providerName + ". Use: " + supported)
            return
        }
        beginSubscriptionLogin(
            provider: provider,
            proxyPort: currentSnapshot.configuration.cliProxy.listenPort
        )
    }

    private func beginSubscriptionLogin(
        provider: CLIProxyLoginProvider,
        proxyPort: Int
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await ensureRuntimeOwnership()
                var candidate = currentSnapshot.configuration
                candidate.cliProxy.enabled = true
                candidate.cliProxy.listenPort = proxyPort
                candidate.reconcileManagedCLIProxyEndpoint()
                try await session.saveConfiguration(candidate)
                let login = try await session.startSubscriptionLogin(provider)
                let code = login.userCode.map { "\nDevice code: \($0)" } ?? ""
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    TUIMessageDialog.show(
                        "Sign in to \(provider.displayName)",
                        message: "Open this URL in a browser:\n\n\(login.url.absoluteString)\(code)\n\nThe URL is copied to the system clipboard. Run subs accounts to check sign-in progress.",
                        width: 86,
                        height: 15
                    )
                    self.writeClipboard(login.url.absoluteString, successMessage: "Sign-in URL copied to clipboard")
                }
            } catch {
                showErrorAsync(error.localizedDescription)
            }
        }
    }

    private func refreshSubscriptionAccounts() {
        guard currentSnapshot.configuration.cliProxy.enabled else {
            showError("Subscription proxy is disabled. Run subs first.")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await ensureRuntimeOwnership()
                try await session.refreshSubscriptionState()
                showStatusAsync("Subscription accounts refreshed")
            } catch {
                showErrorAsync(error.localizedDescription)
            }
        }
    }

    private func cancelSubscriptionLogin() {
        Task { [weak self] in
            guard let self else { return }
            await session.cancelSubscriptionLogin()
            showStatusAsync("Subscription sign-in cancelled")
        }
    }

    private func showSubscriptionAccounts() {
        tabView.selectedTab = TUIPane.subscriptions.rawValue
        showStatus("Subscriptions pane selected")
    }

    private func subscriptionProvider(named name: String) -> CLIProxyLoginProvider? {
        let normalized = name.trimmed.lowercased()
        return CLIProxyLoginProvider.allCases.first {
            $0.rawValue == normalized || $0.displayName.lowercased() == normalized
        }
    }

    private func joinAPIPath(_ base: String, _ component: String) -> String {
        let trimmed = base.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/\(component)" : "/\(trimmed)/\(component)"
    }

    // MARK: - Rendering (main queue)

    fileprivate func render(_ snapshot: AppSnapshot, force: Bool = false) {
        guard !isQuitting else { return }
        if force || currentSnapshot.configuration.tunnels != snapshot.configuration.tunnels {
            tunnelsByID = Dictionary(
                uniqueKeysWithValues: snapshot.configuration.tunnels.map { ($0.id, $0) }
            )
        }
        let sections = TUIRenderInvalidation.sections(
            previous: currentSnapshot,
            next: snapshot,
            force: force
        )
        currentSnapshot = snapshot
        guard !sections.isEmpty else { return }
        if sections.contains(.summary) { renderSummary(snapshot) }
        if sections.contains(.overview) { renderOverview(snapshot) }
        if sections.contains(.tunnels) { renderTunnels(snapshot) }
        if sections.contains(.endpoints) { renderEndpoints(snapshot) }
        if sections.contains(.gateway) { renderGateway(snapshot) }
        if sections.contains(.subscriptions) { renderSubscriptions(snapshot) }
        if sections.contains(.attention) { renderAttention(snapshot) }
        if sections.contains(.settings) { renderSettings(snapshot) }
        if !sections.intersection([.tunnels, .endpoints, .gateway]).isEmpty {
            if let pane = TUIPane(rawValue: selectedPaneIndex) {
                updateContextualHotkeys(for: pane, refresh: false)
            }
            updatePaneStatus()
        }
        if sections.contains(.summary) { summaryLabel.setNeedsDisplay() }
        if !sections.intersection([.overview, .tunnels, .endpoints, .gateway, .subscriptions, .attention, .settings]).isEmpty {
            tabView.setNeedsDisplay()
        }
        // Snapshot-driven renders arrive between input events; TermKit only
        // flushes dirty views after input, so repaint explicitly.
        Application.refresh()
    }

    private func renderSummary(_ snapshot: AppSnapshot) {
        let runtime: String
        switch snapshot.runtimeState {
        case .running:
            runtime = runtimeIsOwned ? "runtime: owned by this console" : "runtime: running"
        case let .ownedExternally(owner):
            runtime = "runtime: owned by \(owner ?? "another process")"
        case .stopped:
            runtime = "runtime: stopped"
        }
        let gateway: String
        switch snapshot.gatewayState {
        case .stopped: gateway = "gateway: stopped"
        case let .running(port): gateway = "gateway: 127.0.0.1:\(port)"
        case .failed: gateway = "gateway: failed"
        }
        summaryLabel.text = " \(runtime)   \(gateway)   moorings: \(snapshot.configuration.tunnels.count)   endpoints: \(snapshot.configuration.endpoints.count)"
    }

    private func renderOverview(_ snapshot: AppSnapshot) {
        var lines: [String] = []
        lines.append("ModelMoor runtime console")
        lines.append("")
        lines.append("Moorings:   \(snapshot.configuration.tunnels.count) (\(snapshot.requestedTunnelIDs.count) requested)")
        lines.append("Endpoints:  \(snapshot.configuration.endpoints.count)")
        lines.append("Routes:     \(snapshot.configuration.routes.count)")
        lines.append("")
        switch snapshot.gatewayState {
        case .stopped:
            lines.append("Unified API: stopped")
        case let .running(port):
            lines.append("Unified API: http://127.0.0.1:\(port)/v1")
        case let .failed(message):
            lines.append("Unified API: failed - \(message)")
        }
        lines.append("")
        lines.append("Tokens last 24h: \(snapshot.usage.lastDay)")
        lines.append("Tokens last 30d: \(snapshot.usage.last30Days)")
        lines.append("")
        lines.append("Shell")
        lines.append("  moor> is the only command and edit entry point.")
        lines.append("  Press : from any pane to focus it, then type help and press Enter.")
        lines.append("  Examples: status | add ssh | add port | subs | gateway")
        lines.append("  Subscription login: subs login codex")
        lines.append("  Copy text: click or Tab to focus, Ctrl-Space + arrows, then Ctrl-C or Alt-W.")
        lines.append("  Copy a selected list row with Ctrl-C.")
        lines.append("")
        lines.append("Focus: Tab or mouse. Keys: \(glyphs.paneRange) panes | ? Help | r refresh | q quit")
        overviewText.text = lines.joined(separator: "\n")
    }

    private func renderSettings(_ snapshot: AppSnapshot) {
        let configuration = snapshot.configuration
        var lines: [String] = [
            "ModelMoor settings",
            "",
            "Configuration",
            "  SSH connections: \(configuration.tunnels.count)",
            "  API endpoints:   \(configuration.endpoints.count)",
            "  Unified API:     \(configuration.gateway.enabled ? "enabled on 127.0.0.1:\(configuration.gateway.listenPort)" : "disabled")",
            "  Subscription proxy: \(configuration.cliProxy.enabled ? "enabled on 127.0.0.1:\(configuration.cliProxy.listenPort)" : "disabled")",
            "",
            "Subscriptions",
            "  See pane \(TUIPane.subscriptions.rawValue) for accounts, sign-in, and proxy status."
        ]
        lines += [
            "",
            "Shell actions",
            "  add ssh, add port, add api",
            "  subs                            Configure provider and proxy port",
            "  subs login <provider>           Start a provider sign-in",
            "  subs accounts                   Open the Subscriptions pane",
            "  subs refresh, cancel            Refresh accounts or cancel sign-in",
            "  gateway                         Configure Unified API port and authentication",
            "  :                               Focus the shell; type help for command details",
            "",
            "Text is read-only. Focus it with Tab or mouse; Ctrl-Space + arrows selects, Ctrl-C copies.",
            "Focused lists copy their selected row with Ctrl-C.",
            "API keys are masked here and stored in the system keychain."
        ]
        settingsText.text = lines.joined(separator: "\n")
    }

    private func renderSubscriptions(_ snapshot: AppSnapshot) {
        let subscriptions = snapshot.subscriptions
        let configuration = snapshot.configuration.cliProxy
        var lines = [
            "Subscriptions",
            "",
            "Proxy:  " + (configuration.enabled
                ? "enabled on 127.0.0.1:\(configuration.listenPort)"
                : "disabled"),
            "Helper: " + subscriptionRuntimeDescription(subscriptions.runtimeState)
        ]
        if let provider = subscriptions.activeProvider,
           let login = subscriptions.activeLogin {
            lines += [
                "",
                "Active sign-in: " + provider.displayName,
                "URL: " + login.url.absoluteString
            ]
            if let code = login.userCode {
                lines.append("Device code: " + code)
            }
        }
        if let error = subscriptions.errorMessage {
            lines += ["", "Error: " + error]
        }
        lines.append("")
        if subscriptions.accounts.isEmpty {
            lines.append("No connected accounts.")
        } else {
            lines.append("Accounts:")
            for account in subscriptions.accounts {
                let state = account.disabled ? "disabled" : (account.status ?? "ready")
                let identity = account.email ?? account.account ?? account.name
                lines.append("  " + account.provider + " | " + identity + " | " + state)
            }
        }
        lines += [
            "",
            "Shell actions",
            "  subs                            Configure the subscription proxy",
            "  subs login <provider>           Start a provider sign-in",
            "  subs accounts                   Return to this page",
            "  subs refresh                    Refresh accounts and proxy health",
            "  subs cancel                     Cancel the active sign-in",
            "",
            "Text is read-only. Focus it with Tab or mouse; Ctrl-Space + arrows selects, Ctrl-C copies."
        ]
        subscriptionsText.text = lines.joined(separator: "\n")
    }

    private func subscriptionRuntimeDescription(_ state: CLIProxyRuntimeState) -> String {
        switch state {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case let .failed(message): "failed: \(message)"
        }
    }

    private func renderTunnels(_ snapshot: AppSnapshot) {
        let query = listFilters[.sshConnections] ?? PresentationSearchQuery("")
        let source = snapshot.configuration.tunnels
        let documents = tunnelSearchDocuments.prepare(for: source) { tunnels in
            tunnels.map { tunnel in
                PresentationSearchDocument(
                    fields: [tunnel.name, tunnel.sshHost] + tunnel.mappings.map(\.name)
                )
            }
        }
        let tunnels = zip(source, documents).compactMap { tunnel, document in
            query.matches(document: document) ? tunnel : nil
        }
        let visibleIDs = tunnels.map(\.id)
        let selection = tunnelSelection.resolvedIndex(
            visibleIDs: visibleIDs,
            allIDs: snapshot.configuration.tunnels.map(\.id),
            fallbackIndex: tunnelsList.selectedItem
        )
        listedTunnelIDs = visibleIDs
        let items = tunnels.map { tunnel -> String in
            let status = snapshot.tunnelStatus(for: tunnel.id)
            let marker: String
            switch status.phase {
            case .connected: marker = glyphs.active
            case .connecting, .waitingToRetry, .waitingForNetwork: marker = glyphs.pending
            case .failed: marker = glyphs.failed
            case .stopped, .disconnecting: marker = glyphs.inactive
            }
            let requested = snapshot.requestedTunnelIDs.contains(tunnel.id) ? glyphs.requested : " "
            return "\(marker)\(requested) \(tunnel.name)  ssh:\(tunnel.sshHost)  \(status.phase.rawValue)  \(status.message)"
        }
        let emptyMessage = query.isEmpty
            ? "(no moorings configured - use the CLI or the macOS app)"
            : "(no SSH connections match the active filter - press x to clear)"
        tunnelsList.items = items.isEmpty ? [emptyMessage] : items
        if let selection {
            tunnelsList.selectedItem = selection
        }
        observedTunnelSelectionIndex = selection
    }

    private func renderEndpoints(_ snapshot: AppSnapshot) {
        let query = listFilters[.apiEndpoints] ?? PresentationSearchQuery("")
        let endpoints = snapshot.configuration.endpoints
        let source = EndpointSearchSource(
            endpoints: endpoints,
            modelIDsByEndpointID: Dictionary(uniqueKeysWithValues: endpoints.map { endpoint in
                (endpoint.id, snapshot.inspections[endpoint.id]?.models?.map(\.id) ?? [])
            })
        )
        let documents = endpointSearchDocuments.prepare(for: source) { source in
            source.endpoints.map { endpoint in
                PresentationSearchDocument(
                    fields: [endpoint.name, endpoint.kind.rawValue]
                        + source.modelIDsByEndpointID[endpoint.id, default: []]
                )
            }
        }
        let visibleEndpoints = zip(source.endpoints, documents).compactMap { endpoint, document in
            query.matches(document: document) ? endpoint : nil
        }
        let visibleIDs = visibleEndpoints.map(\.id)
        let selection = endpointSelection.resolvedIndex(
            visibleIDs: visibleIDs,
            allIDs: snapshot.configuration.endpoints.map(\.id),
            fallbackIndex: endpointsList.selectedItem
        )
        listedEndpointIDs = visibleIDs
        let items = visibleEndpoints.map { endpoint -> String in
            let marker = endpoint.enabled ? glyphs.active : glyphs.inactive
            let state: String
            if !EndpointInteractionPolicy.hasRequiredCredential(
                endpoint,
                availableAPIKeyIDs: snapshot.availableEndpointAPIKeyIDs
            ) {
                state = "missing API key"
            } else if let inspection = snapshot.inspections[endpoint.id] {
                if let models = inspection.models {
                    state = "\(models.count) models"
                } else if let error = inspection.errorMessage {
                    state = "error: \(error)"
                } else if let code = inspection.statusCode {
                    state = "HTTP \(code)"
                } else {
                    state = "unknown"
                }
            } else {
                state = "not probed (press r)"
            }
            return "\(marker) \(endpoint.name)  \(endpoint.kind.rawValue)  \(state)"
        }
        let emptyMessage = query.isEmpty
            ? "(no endpoints configured)"
            : "(no API endpoints match the active filter - press x to clear)"
        endpointsList.items = items.isEmpty ? [emptyMessage] : items
        if let selection {
            endpointsList.selectedItem = selection
        }
        observedEndpointSelectionIndex = selection
    }

    private func renderGateway(_ snapshot: AppSnapshot) {
        let heading: String
        switch snapshot.gatewayState {
        case .stopped:
            heading = "Unified API is stopped."
        case let .running(port):
            heading = "Unified API: http://127.0.0.1:\(port)/v1"
        case let .failed(message):
            heading = "Unified API failed: \(message)"
        }
        gatewayText.text = heading + "\n\nModel routes (select one, then press m to copy its public name):"

        let query = listFilters[.unifiedAPI] ?? PresentationSearchQuery("")
        let endpointNames = Dictionary(
            uniqueKeysWithValues: snapshot.configuration.endpoints.map { ($0.id, $0.name) }
        )
        let source = RouteSearchSource(
            routes: snapshot.configuration.routes,
            endpointNames: endpointNames
        )
        let documents = routeSearchDocuments.prepare(for: source) { source in
            source.routes.map { route in
                PresentationSearchDocument(fields: [
                    route.publicModel,
                    route.upstreamModel,
                    source.endpointNames[route.endpointID] ?? "missing"
                ])
            }
        }
        let routes = zip(source.routes, documents).compactMap { route, document in
            query.matches(document: document) ? route : nil
        }
        let visibleIDs = routes.map(\.id)
        let selection = routeSelection.resolvedIndex(
            visibleIDs: visibleIDs,
            allIDs: snapshot.configuration.routes.map(\.id),
            fallbackIndex: routesList.selectedItem
        )
        listedRouteIDs = visibleIDs
        let items = routes.map { route in
            let endpoint = endpointNames[route.endpointID] ?? "missing"
            let marker = route.enabled ? glyphs.active : glyphs.inactive
            return "\(marker) \(route.publicModel) -> \(endpoint):\(route.upstreamModel)"
        }
        let emptyMessage = query.isEmpty
            ? "(no model routes configured)"
            : "(no model routes match the active filter - press x to clear)"
        routesList.items = items.isEmpty ? [emptyMessage] : items
        if let selection {
            routesList.selectedItem = selection
        }
        observedRouteSelectionIndex = selection
    }

    private func renderAttention(_ snapshot: AppSnapshot) {
        var lines: [String] = []
        let failedTunnels = snapshot.configuration.tunnels.filter {
            snapshot.tunnelStatus(for: $0.id).phase == .failed
        }
        for tunnel in failedTunnels {
            let status = snapshot.tunnelStatus(for: tunnel.id)
            lines.append("\(glyphs.failed) Mooring \(tunnel.name): \(status.message)")
        }
        for endpoint in snapshot.configuration.endpoints where endpoint.enabled {
            if !EndpointInteractionPolicy.hasRequiredCredential(
                endpoint,
                availableAPIKeyIDs: snapshot.availableEndpointAPIKeyIDs
            ) {
                lines.append("\(glyphs.failed) Endpoint \(endpoint.name): missing API key")
                continue
            }
            guard let inspection = snapshot.inspections[endpoint.id],
                  !inspection.isReachable else { continue }
            lines.append("\(glyphs.failed) Endpoint \(endpoint.name): \(inspection.errorMessage ?? "unreachable")")
        }
        if case let .failed(message) = snapshot.gatewayState {
            lines.append("\(glyphs.failed) Unified API: \(message)")
        }
        if case let .ownedExternally(owner) = snapshot.runtimeState {
            lines.append("\(glyphs.info) Runtime owned by \(owner ?? "another process") - connect/retry here would need it stopped first.")
        }
        if lines.isEmpty {
            lines.append("Nothing needs attention.")
        }
        lines.append("")
        lines.append("--- Diagnostics (redacted) ---")
        attentionBaseText = lines.joined(separator: "\n")
        attentionText.text = attentionBaseText
        if let selectedPane = TUIPane(rawValue: selectedPaneIndex),
           TUIVisibilityWorkPolicy.shouldLoadDiagnostics(selectedPane: selectedPane) {
            refreshAttentionDiagnostics()
        } else {
            cancelAttentionDiagnostics()
        }
    }

    /// Diagnostic history can grow to the bounded log limit and is irrelevant
    /// while another pane is visible. Load it on entry and whenever the visible
    /// attention state changes; cancel immediately when the user leaves.
    private func refreshAttentionDiagnostics() {
        guard let selectedPane = TUIPane(rawValue: selectedPaneIndex),
              TUIVisibilityWorkPolicy.shouldLoadDiagnostics(selectedPane: selectedPane),
              !isQuitting else { return }
        let renderID = UUID()
        attentionRenderID = renderID
        attentionText.text = attentionBaseText + "\nLoading diagnostics..."
        attentionText.setNeedsDisplay()
        let newDiagnosticsTask = Task { [weak self] in
            guard let self else { return }
            let summary = await session.diagnosticSummary()
            guard !Task.isCancelled else { return }
            await MainActorless.appendDiagnostics(self, summary: summary, renderID: renderID)
        }
        let previousTask = lifecycleLock.withLock { () -> Task<Void, Never>? in
            let previous = diagnosticsTask
            diagnosticsTask = newDiagnosticsTask
            return previous
        }
        previousTask?.cancel()
    }

    private func cancelAttentionDiagnostics() {
        attentionRenderID = UUID()
        let task = lifecycleLock.withLock { () -> Task<Void, Never>? in
            let task = diagnosticsTask
            diagnosticsTask = nil
            return task
        }
        task?.cancel()
    }

    fileprivate func appendDiagnostics(_ summary: String, renderID: UUID) {
        guard !isQuitting,
              let selectedPane = TUIPane(rawValue: selectedPaneIndex),
              TUIVisibilityWorkPolicy.shouldLoadDiagnostics(selectedPane: selectedPane),
              renderID == attentionRenderID else { return }
        attentionText.text = attentionBaseText + "\n"
            + (summary.isEmpty ? "No diagnostic events yet." : summary)
        attentionText.setNeedsDisplay()
        Application.refresh()
    }

    fileprivate func showError(_ message: String) {
        guard !isQuitting else { return }
        shellFeedback.text = "ERROR: " + message
        shellFeedback.setNeedsDisplay()
        statusBar.pushStatus("Error: \(message)", timeout: 8)
        Application.refresh()
    }

    fileprivate func showStatus(_ message: String) {
        guard !isQuitting else { return }
        shellFeedback.text = "OK: " + message
        shellFeedback.setNeedsDisplay()
        statusBar.pushStatus(message, timeout: 4)
        Application.refresh()
    }

    private func focusShell(message: String = "SHELL ACTIVE: type a command and press Enter") {
        _ = shellInput.becomeFirstResponder()
        shellFeedback.text = message
        shellFeedback.setNeedsDisplay()
        Application.refresh()
    }

    fileprivate func setRefreshIndicator(_ visible: Bool) {
        guard !isQuitting else { return }
        if visible {
            statusBar.showSpinner(
                id: "refreshing",
                message: "Refreshing endpoint status",
                priority: .veryHigh,
                kind: glyphs.usesASCII ? Spinner.line : Spinner.dot,
                placement: .leading
            )
        } else {
            statusBar.hideIndicator(id: "refreshing")
        }
        Application.refresh()
    }

    private func showErrorAsync(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.showError(message) }
    }

    private func showStatusAsync(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.showStatus(message) }
    }

    private func synchronizeRefreshIndicatorAsync() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let visible = lifecycleLock.withLock { refreshCoalescer.isRefreshing }
            setRefreshIndicator(visible)
        }
    }

    private func selectedTunnelID() -> UUID? {
        guard !listedTunnelIDs.isEmpty else { return nil }
        let index = min(max(tunnelsList.selectedItem, 0), listedTunnelIDs.count - 1)
        return listedTunnelIDs[index]
    }

    private func selectedTunnel() -> TunnelConfiguration? {
        guard let tunnelID = selectedTunnelID(),
              let tunnel = tunnelsByID[tunnelID] else {
            return nil
        }
        return tunnel
    }

    /// Clipboard helpers can launch a process and wait for it. Resolve every
    /// target from TermKit state on the main queue first, then perform only the
    /// blocking system write in the task.
    private func writeClipboard(_ value: String, successMessage: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try SystemClipboard.copy(value)
                self?.showStatusAsync(successMessage)
            } catch {
                self?.showErrorAsync(error.localizedDescription)
            }
        }
    }
}

private struct EndpointSearchSource: Equatable, Sendable {
    let endpoints: [APIEndpointConfiguration]
    let modelIDsByEndpointID: [UUID: [String]]
}

private struct RouteSearchSource: Equatable, Sendable {
    let routes: [ModelRouteConfiguration]
    let endpointNames: [UUID: String]
}

/// TextField accepts carriage return by default. Some terminal drivers send
/// line feed instead, so accept both forms for the bottom command shell.
private final class ShellTextField: TextField {
    override func processKey(event: KeyEvent) -> Bool {
        if case .controlJ = event.key, onSubmit != nil {
            onSubmit?(self)
            return true
        }
        return super.processKey(event: event)
    }
}

private final class KeyHandlingWindow: Window {
    private let usesASCIIBorder: Bool
    var globalKeyHandler: ((KeyEvent) -> Bool)?
    var interactionDidFinish: (() -> Void)?

    init(_ title: String?, usesASCIIBorder: Bool) {
        self.usesASCIIBorder = usesASCIIBorder
        super.init(title)
    }

    override func redraw(region: Rect, painter: Painter) {
        guard usesASCIIBorder else {
            super.redraw(region: region, painter: painter)
            return
        }
        painter.attribute = colorScheme.normal
        painter.clear(bounds)
        let width = max(0, bounds.width)
        let height = max(0, bounds.height)
        guard width >= 2, height >= 2 else { return }

        let horizontal = "+" + String(repeating: "-", count: width - 2) + "+"
        painter.goto(col: 0, row: 0)
        painter.add(str: horizontal)
        for row in 1..<(height - 1) {
            painter.goto(col: 0, row: row)
            painter.add(str: "|")
            painter.goto(col: width - 1, row: row)
            painter.add(str: "|")
        }
        painter.goto(col: 0, row: height - 1)
        painter.add(str: horizontal)

        if let title, width > 4 {
            let available = max(0, width - 4)
            painter.goto(col: 2, row: 0)
            painter.add(str: " \(String(title.prefix(available))) ")
        }
    }

    override func processKey(event: KeyEvent) -> Bool {
        let handled = globalKeyHandler?(event) == true
            ? true
            : super.processKey(event: event)
        interactionDidFinish?()
        return handled
    }

    override func mouseEvent(event: MouseEvent) -> Bool {
        let handled = super.mouseEvent(event: event)
        interactionDidFinish?()
        return handled
    }
}

/// Small trampoline so background tasks can reach the main queue without
/// importing a MainActor-locked type.
private enum MainActorless {
    static func render(_ app: TUIApp, snapshot: AppSnapshot) async {
        DispatchQueue.main.async { app.render(snapshot) }
    }

    static func appendDiagnostics(_ app: TUIApp, summary: String, renderID: UUID) async {
        DispatchQueue.main.async { app.appendDiagnostics(summary, renderID: renderID) }
    }

    static func showError(_ app: TUIApp, message: String) async {
        DispatchQueue.main.async { app.showError(message) }
    }

    static func activateVisibleWork(_ app: TUIApp) async {
        DispatchQueue.main.async { app.activateVisibleWork() }
    }

    static func shouldInspectEndpoints(_ app: TUIApp) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: app.shouldInspectEndpoints())
            }
        }
    }

    static func requestStop() {
        DispatchQueue.main.async { Application.requestStop() }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var isTruthy: Bool {
        ["1", "true", "yes", "y", "on"].contains(trimmed.lowercased())
    }
}

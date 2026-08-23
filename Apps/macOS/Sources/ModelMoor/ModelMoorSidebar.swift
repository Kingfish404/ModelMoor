import AppKit
import ModelMoorApplication
import ModelMoorCore
import ModelMoorSystem
import SwiftUI

struct ModelMoorSidebar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var dirtyDrafts: DirtyDraftCoordinator
    @EnvironmentObject private var sidebarSearchFocus: SidebarSearchFocusCoordinator
    @Binding var selection: NavigationSelection?
    let addEndpoint: () -> Void
    let addSSHConnection: () -> Void
    @State private var isOthersExpanded = false
    @State private var searchText = ""
    @State private var searchIndexCache = SidebarSearchIndexCache()

    var body: some View {
        VStack(spacing: 0) {
            primaryNavigation
            Divider()
            utilityNavigation
                .frame(height: SidebarMetrics.utilityListHeight)
        }
        .navigationTitle(model.runtimeProfile.displayName)
        .modifier(SidebarSearchModifier(text: $searchText, coordinator: sidebarSearchFocus))
        .onChange(of: selection) { _, newSelection in
            guard case let .endpoint(id)? = newSelection,
                  allOtherEndpoints.contains(where: { $0.id == id }) else { return }
            isOthersExpanded = true
        }
    }

    private var primaryNavigation: some View {
        let query = PresentationSearchQuery(searchText)
        let hasSearchQuery = !query.isEmpty
        let contents = searchIndexCache.index(
            sourceRevision: model.sidebarSearchSourceRevision,
            configuration: model.configuration,
            inspections: model.inspections,
            query: query
        )
        let connectionNamesByMappingID = contents.connectionNamesByMappingID
        let tunnels = contents.tunnels
        let endpoints = contents.llmEndpoints
        let forwardedEndpoints = contents.otherEndpoints
        let portForwards = contents.portForwards
        let resultCount = tunnels.count + endpoints.count + forwardedEndpoints.count + portForwards.count
        let selectionRecovery = hasSearchQuery
            && !SidebarSearchSelectionVisibility.isVisible(selection, in: contents)
            ? SidebarSearchSelectionVisibility.recovery(
                selection,
                configuration: model.configuration,
                inspections: model.inspections
            )
            : nil
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: SidebarMetrics.sectionSpacing) {
                VStack(spacing: SidebarMetrics.rowSpacingVertical) {
                    SidebarNavigationButton(
                        title: AppLocalization.string("Overview"),
                        symbol: "gauge.with.dots.needle.50percent",
                        destination: .overview,
                        selection: $selection
                    )

                    SidebarNavigationButton(
                        title: AppLocalization.string("Unified API"),
                        subtitle: unifiedSubtitle,
                        symbol: gatewaySymbol,
                        destination: .gateway,
                        selection: $selection
                    )
                }

                VStack(alignment: .leading, spacing: SidebarMetrics.rowSpacingVertical) {
                    SidebarSectionHeader(
                        title: AppLocalization.string("SSH Connections"),
                        actionLabel: AppLocalization.string("Add SSH Connection"),
                        action: addSSHConnection
                    )
                    .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)

                    ForEach(tunnels) { connection in
                        connectionRow(
                            connection,
                            endpointCounts: contents.endpointCountsByTunnelID[connection.id, default: .zero]
                        )
                    }
                }

                VStack(alignment: .leading, spacing: SidebarMetrics.rowSpacingVertical) {
                    SidebarSectionHeader(
                        title: AppLocalization.string("API Endpoints"),
                        actionLabel: AppLocalization.string("Add API Endpoint"),
                        action: addEndpoint
                    )
                    .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)

                    ForEach(endpoints) { endpoint in
                        endpointRow(endpoint, connectionNamesByMappingID: connectionNamesByMappingID)
                    }
                }

                SidebarNavigationButton(
                    title: AppLocalization.string("Subscription"),
                    subtitle: subscriptionSubtitle,
                    symbol: subscriptionSymbol,
                    symbolColor: subscriptionSymbolColor,
                    destination: .subscriptionAccounts,
                    selection: $selection
                )

                if !forwardedEndpoints.isEmpty || !portForwards.isEmpty {
                    VStack(alignment: .leading, spacing: SidebarMetrics.rowSpacingVertical) {
                        SidebarSectionHeader(
                            title: AppLocalization.string("Others"),
                            actionLabel: hasSearchQuery
                                ? AppLocalization.string("Clear Search")
                                : AppLocalization.string(isOthersExpanded ? "Collapse Others" : "Expand Others"),
                            actionSymbol: hasSearchQuery
                                ? "xmark.circle"
                                : (isOthersExpanded ? "chevron.down" : "chevron.right")
                        ) {
                            if hasSearchQuery {
                                searchText = ""
                            } else {
                                isOthersExpanded.toggle()
                            }
                        }
                        .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)

                        if isOthersExpanded || hasSearchQuery {
                            ForEach(forwardedEndpoints) { endpoint in
                                SidebarNavigationButton(
                                    title: endpoint.name,
                                    subtitle: "\(sourceSummary(endpoint, connectionNamesByMappingID: connectionNamesByMappingID)), forwarded service",
                                    symbol: "arrow.left.arrow.right",
                                    isMuted: !endpoint.enabled,
                                    destination: .endpoint(endpoint.id),
                                    selection: $selection
                                )
                                .contextMenu {
                                    let resolvedURL = model.endpointURL(endpoint)
                                    Button("Copy URL") {
                                        guard let resolvedURL else { return }
                                        model.copy(resolvedURL.absoluteString)
                                    }
                                    .disabled(!EndpointInteractionPolicy.canCopyURL(resolvedURL))
                                    if EndpointInteractionPolicy.canDuplicate(endpoint) {
                                        Button("Duplicate API Endpoint") {
                                            duplicateEndpointAfterResolvingDraft(endpoint.id)
                                        }
                                    }
                                    Button("Show in ModelMoor") { selection = .endpoint(endpoint.id) }
                                }
                            }
                            ForEach(portForwards) { item in
                                SidebarNavigationButton(
                                    title: "\(item.connection.name) / \(item.mapping.name)",
                                    subtitle: portForwardSummary(item.mapping),
                                    symbol: "arrow.left.arrow.right",
                                    destination: .connection(item.connection.id),
                                    selection: $selection
                                )
                                .contextMenu {
                                    Button(item.mapping.direction.listensLocally ? "Copy Local Address" : "Copy Remote Address") {
                                        model.copy("\(item.mapping.listenHost):\(item.mapping.listenPort)")
                                    }
                                    Button("Show SSH Connection") { selection = .connection(item.connection.id) }
                                }
                            }
                        }
                    }
                }

                if hasSearchQuery && resultCount == 0 {
                    Label("No matching connections or endpoints", systemImage: "magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)
                        .padding(.vertical, 8)
                        .accessibilityLabel("No matching connections or endpoints")
                }

                if let selectionRecovery {
                    Button {
                        if selectionRecovery == .clearSearchAndExpandOthers {
                            isOthersExpanded = true
                        }
                        searchText = ""
                    } label: {
                        HStack(spacing: 8) {
                            Label(
                                "Current selection is hidden by search",
                                systemImage: "eye.slash"
                            )
                            .lineLimit(2)
                            Spacer(minLength: 8)
                            Text("Clear Search")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tint)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Current selection is hidden by search")
                    .accessibilityHint("Clear Search")
                }
            }
            .padding(.horizontal, SidebarMetrics.utilityHorizontalPadding)
            .padding(.vertical, SidebarMetrics.primaryVerticalPadding)
        }
    }

    private var utilityNavigation: some View {
        VStack(spacing: SidebarMetrics.utilitySpacing) {
            SidebarNavigationButton(
                title: AppLocalization.string("Usage"),
                subtitle: AppLocalization.format(
                    "%@ tokens in 24 hours",
                    TokenCountFormatter.compact(model.tokenUsage.lastDay)
                ),
                symbol: "chart.xyaxis.line",
                destination: .usage,
                selection: $selection
            )

            SidebarNavigationButton(
                title: AppLocalization.string("Settings"),
                symbol: "gearshape",
                destination: .settings,
                selection: $selection
            )
        }
        .padding(.horizontal, SidebarMetrics.utilityHorizontalPadding)
        .padding(.vertical, SidebarMetrics.utilityVerticalPadding)
        .accessibilityLabel("Usage and Settings")
    }

    private var allOtherEndpoints: [APIEndpointConfiguration] {
        model.configuration.endpoints.filter { !model.isRecognizedLLMEndpoint($0) }
    }

    private func endpointRow(
        _ endpoint: APIEndpointConfiguration,
        connectionNamesByMappingID: [UUID: String]
    ) -> some View {
        let readiness = readiness(endpoint)
        return SidebarNavigationButton(
            title: endpoint.name,
            subtitle: "\(sourceSummary(endpoint, connectionNamesByMappingID: connectionNamesByMappingID)), \(readiness.title)",
            symbol: readiness.symbol,
            symbolColor: readinessColor(readiness),
            isMuted: !endpoint.enabled,
            destination: .endpoint(endpoint.id),
            selection: $selection
        )
        .contextMenu {
            let resolvedURL = model.endpointURL(endpoint)
            Button("Copy URL") {
                guard let resolvedURL else { return }
                model.copy(resolvedURL.absoluteString)
            }
            .disabled(!EndpointInteractionPolicy.canCopyURL(resolvedURL))
            Button("Refresh") { Task { await model.inspectEndpoint(endpoint.id) } }
                .disabled(!EndpointInteractionPolicy.canRefresh(
                    endpoint,
                    inspectingEndpointIDs: model.inspectingEndpointIDs
                ))
            if EndpointInteractionPolicy.canDuplicate(endpoint) {
                Button("Duplicate API Endpoint") {
                    duplicateEndpointAfterResolvingDraft(endpoint.id)
                }
            }
            Divider()
            Button("Show in ModelMoor") { selection = .endpoint(endpoint.id) }
        }
    }

    private func connectionRow(
        _ connection: TunnelConfiguration,
        endpointCounts: SidebarEndpointCounts
    ) -> some View {
        let phase = model.status(for: connection.id).phase
        return SidebarNavigationButton(
            title: connection.name,
            subtitle: connectionSubtitle(connection, endpointCounts: endpointCounts),
            symbol: connectionSymbol(connection),
            destination: .connection(connection.id),
            selection: $selection
        )
        .contextMenu {
            Button(phase.connectionActionTitle) {
                Task {
                    if phase.usesDisconnectAction { await model.disconnect(connection.id) }
                    else { await model.connect(connection.id) }
                }
            }
            .disabled(!ConnectionInteractionPolicy.canPerformPrimaryAction(
                connection,
                phase: phase
            ))
            Button("Run diagnostics") { Task { await model.inspectMappings(in: connection.id) } }
            Divider()
            Button("Show in ModelMoor") { selection = .connection(connection.id) }
        }
    }

    private func readinessColor(_ readiness: EndpointReadiness) -> Color {
        switch readiness {
        case .disabled: .secondary
        case .ready: .green
        case .needsAttention: .orange
        case .checking: .accentColor
        case .unknown: .secondary
        }
    }

    private func duplicateEndpointAfterResolvingDraft(_ endpointID: UUID) {
        dirtyDrafts.requestTransition {
            Task { await model.duplicateEndpoint(endpointID) }
        }
    }

    private func readiness(_ endpoint: APIEndpointConfiguration) -> EndpointReadiness {
        guard endpoint.enabled else { return .disabled }
        guard !model.inspectingEndpointIDs.contains(endpoint.id) else { return .checking }
        if endpoint.authentication != .none, !model.hasToken(for: endpoint.id) {
            return .needsAttention("Add API key")
        }
        guard let inspection = model.inspections[endpoint.id] else { return .unknown }
        if let error = inspection.errorMessage { return .needsAttention(error) }
        return .ready(inspection.models?.count ?? 0)
    }

    private func sourceSummary(
        _ endpoint: APIEndpointConfiguration,
        connectionNamesByMappingID: [UUID: String]
    ) -> String {
        switch endpoint.source {
        case let .directHTTPS(origin): return origin.host ?? "Direct HTTPS"
        case .managedCLIProxy: return "Subscription accounts"
        case let .sshMapping(mappingID, _):
            if let connectionName = connectionNamesByMappingID[mappingID] {
                return "via \(connectionName)"
            }
            return "Missing SSH connection"
        }
    }

    private func portForwardSummary(_ mapping: PortMappingConfiguration) -> String {
        let listen = "\(mapping.listenHost):\(mapping.listenPort)"
        if mapping.direction.isDynamic {
            let location = mapping.direction.listensLocally ? "local" : "remote"
            return "\(mapping.direction.sshFlag), \(location) SOCKS 4/5 at \(listen)"
        }
        let destination = "\(mapping.destinationHost):\(mapping.destinationPort)"
        return mapping.direction == .local
            ? "-L, local \(listen) to remote \(destination)"
            : "-R, remote \(listen) to local \(destination)"
    }

    private var unifiedSubtitle: String {
        if !model.configuration.gateway.enabled { return AppLocalization.string("Disabled")
        }
        let count = model.configuration.routes.filter(\.enabled).count
        switch model.gatewayState {
        case .stopped: return AppLocalization.format("Starting, %lld models", Int64(count))
        case .running:
            return AppLocalization.format(count == 1 ? "Ready, %lld model" : "Ready, %lld models", Int64(count))
        case .failed: return AppLocalization.string("Needs attention")
        }
    }

    private var subscriptionSubtitle: String {
        if case .failed = model.cliProxyState { return AppLocalization.string("Needs attention") }
        if model.activeSubscriptionLogin != nil { return AppLocalization.string("Waiting for sign-in") }
        let total = model.subscriptionAccounts.count
        guard total > 0 else { return AppLocalization.string("No accounts connected") }
        let active = model.subscriptionAccounts.filter { !$0.disabled }.count
        if total == 1 {
            return AppLocalization.string(active == 1 ? "1 active account" : "1 disabled account")
        }
        return AppLocalization.format("%lld active of %lld accounts", Int64(active), Int64(total))
    }

    private var subscriptionSymbol: String {
        if case .failed = model.cliProxyState { return "exclamationmark.triangle.fill" }
        if model.activeSubscriptionLogin != nil { return "person.crop.circle.badge.clock" }
        return model.subscriptionAccounts.isEmpty ? "person.2.badge.plus" : "person.2.fill"
    }

    private var subscriptionSymbolColor: Color {
        if case .failed = model.cliProxyState { return .orange }
        return model.subscriptionAccounts.contains { !$0.disabled } ? .green : .secondary
    }

    private var gatewaySymbol: String {
        switch model.gatewayState {
        case .running: "point.3.connected.trianglepath.dotted"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: model.configuration.gateway.enabled ? "clock" : "circle"
        }
    }

    private func connectionSubtitle(
        _ connection: TunnelConfiguration,
        endpointCounts: SidebarEndpointCounts
    ) -> String {
        let status = model.status(for: connection.id).message
        var parts = [status]
        if endpointCounts.llm > 0 {
            parts.append(endpointCounts.llm == 1 ? "1 endpoint" : "\(endpointCounts.llm) endpoints")
        }
        if endpointCounts.other > 0 {
            parts.append(endpointCounts.other == 1 ? "1 other" : "\(endpointCounts.other) others")
        }
        return parts.joined(separator: ", ")
    }

    private func connectionSymbol(_ connection: TunnelConfiguration) -> String {
        switch model.status(for: connection.id).phase {
        case .stopped: "circle"
        case .waitingForNetwork: "wifi.slash"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .disconnecting: "stop.circle"
        case .waitingToRetry: "clock.arrow.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let actionLabel: String
    var actionSymbol = "plus"
    let action: () -> Void

    var body: some View {
        HStack(spacing: SidebarMetrics.headerSpacing) {
            Text(title)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(action: action) {
                Image(systemName: actionSymbol)
                    .imageScale(.small)
                    .frame(width: SidebarMetrics.headerControlSize, height: SidebarMetrics.headerControlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(actionLabel)
            .help(actionLabel)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(minHeight: SidebarMetrics.headerControlSize)
    }
}

private enum SidebarMetrics {
    static let iconSize: CGFloat = 18
    static let textSpacing: CGFloat = 2
    static let rowSpacing: CGFloat = 9
    static let rowHeight: CGFloat = 36
    static let rowSpacingVertical: CGFloat = 2
    static let rowHorizontalPadding: CGFloat = 8
    static let sectionSpacing: CGFloat = 14
    static let headerSpacing: CGFloat = 8
    static let headerControlSize: CGFloat = 18
    static let utilitySpacing: CGFloat = 2
    static let utilityHorizontalPadding: CGFloat = 8
    static let primaryVerticalPadding: CGFloat = 8
    static let utilityVerticalPadding: CGFloat = 6
    static let utilityListHeight: CGFloat = 86
}

private struct SidebarNavigationButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState
    let title: String
    var subtitle: String?
    let symbol: String
    var symbolColor: Color = .secondary
    var isMuted = false
    let destination: NavigationSelection
    @Binding var selection: NavigationSelection?
    @State private var isHovering = false
    @FocusState private var isKeyboardFocused: Bool

    private var isSelected: Bool { selection == destination }

    var body: some View {
        Button {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selection = destination
            }
        } label: {
            HStack(alignment: .center, spacing: SidebarMetrics.rowSpacing) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .imageScale(.medium)
                    .foregroundStyle(iconColor)
                    .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SidebarMetrics.textSpacing) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(foregroundColor)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(foregroundColor.opacity(isSelected ? 0.78 : 0.64))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(height: SidebarMetrics.rowHeight, alignment: .center)
            .contentShape(Rectangle())
            .background(selectionBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(StableSidebarButtonStyle())
        .focused($isKeyboardFocused)
        .overlay {
            if isKeyboardFocused {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(1)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle ?? "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onHover { isHovering = $0 }
    }

    private var foregroundColor: Color {
        if isSelected {
            if controlActiveState == .inactive {
                return Color(nsColor: .unemphasizedSelectedTextColor)
            }
            return colorScheme == .light
                ? .white
                : Color(nsColor: .selectedControlTextColor)
        }
        return isMuted ? Color.secondary.opacity(0.72) : .primary
    }

    private var iconColor: Color {
        if isSelected { return foregroundColor.opacity(0.9) }
        return symbolColor.opacity(isMuted ? 0.5 : 1)
    }

    private var selectionBackground: Color {
        if isSelected {
            if controlActiveState == .inactive {
                return Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
            }
            return Color(nsColor: .selectedContentBackgroundColor)
        }
        if isHovering {
            return Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.055)
        }
        return .clear
    }
}

private struct StableSidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(
                maxWidth: .infinity,
                minHeight: SidebarMetrics.rowHeight,
                maxHeight: SidebarMetrics.rowHeight,
                alignment: .leading
            )
    }
}

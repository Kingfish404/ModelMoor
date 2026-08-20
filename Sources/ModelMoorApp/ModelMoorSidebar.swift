import AppKit
import ModelMoorCore
import SwiftUI

struct ModelMoorSidebar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: NavigationSelection?
    let addEndpoint: () -> Void
    let addSSHConnection: () -> Void
    @State private var isOthersExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            primaryNavigation
            Divider()
            utilityNavigation
                .frame(height: SidebarMetrics.utilityListHeight)
        }
        .navigationTitle(model.runtimeProfile.displayName)
        .onChange(of: selection) { _, newSelection in
            guard case let .endpoint(id)? = newSelection,
                  otherEndpoints.contains(where: { $0.id == id }) else { return }
            isOthersExpanded = true
        }
    }

    private var primaryNavigation: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SidebarMetrics.sectionSpacing) {
                VStack(spacing: SidebarMetrics.rowSpacingVertical) {
                    SidebarNavigationButton(
                        title: "Overview",
                        symbol: "gauge.with.dots.needle.50percent",
                        destination: .overview,
                        selection: $selection
                    )

                    SidebarNavigationButton(
                        title: "Unified API",
                        subtitle: unifiedSubtitle,
                        symbol: gatewaySymbol,
                        destination: .gateway,
                        selection: $selection
                    )
                }

                VStack(alignment: .leading, spacing: SidebarMetrics.rowSpacingVertical) {
                    SidebarSectionHeader(
                        title: "SSH Connections",
                        actionLabel: "Add SSH Connection",
                        action: addSSHConnection
                    )
                    .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)

                    ForEach(model.configuration.tunnels) { connection in connectionRow(connection) }
                }

                VStack(alignment: .leading, spacing: SidebarMetrics.rowSpacingVertical) {
                    SidebarSectionHeader(
                        title: "API Endpoints",
                        actionLabel: "Add API Endpoint",
                        action: addEndpoint
                    )
                    .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)

                    ForEach(llmEndpoints) { endpoint in endpointRow(endpoint) }
                }

                SidebarNavigationButton(
                    title: "Subscription",
                    subtitle: subscriptionSubtitle,
                    symbol: subscriptionSymbol,
                    symbolColor: subscriptionSymbolColor,
                    destination: .subscriptionAccounts,
                    selection: $selection
                )

                if !otherEndpoints.isEmpty || !otherPortForwards.isEmpty {
                    VStack(alignment: .leading, spacing: SidebarMetrics.rowSpacingVertical) {
                        SidebarSectionHeader(
                            title: "Others",
                            actionLabel: isOthersExpanded ? "Collapse Others" : "Expand Others",
                            actionSymbol: isOthersExpanded ? "chevron.down" : "chevron.right"
                        ) {
                            isOthersExpanded.toggle()
                        }
                        .padding(.horizontal, SidebarMetrics.rowHorizontalPadding)

                        if isOthersExpanded {
                            ForEach(otherEndpoints) { endpoint in
                                SidebarNavigationButton(
                                    title: endpoint.name,
                                    subtitle: "\(sourceSummary(endpoint)), forwarded service",
                                    symbol: "arrow.left.arrow.right",
                                    isMuted: !endpoint.enabled,
                                    destination: .endpoint(endpoint.id),
                                    selection: $selection
                                )
                                .contextMenu {
                                    Button("Copy URL") {
                                        if let url = model.endpointURL(endpoint) { model.copy(url.absoluteString) }
                                    }
                                    if isDirectEndpoint(endpoint) {
                                        Button("Duplicate API Endpoint") {
                                            Task { await model.duplicateEndpoint(endpoint.id) }
                                        }
                                    }
                                    Button("Show in ModelMoor") { selection = .endpoint(endpoint.id) }
                                }
                            }
                            ForEach(otherPortForwards) { item in
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
            }
            .padding(.horizontal, SidebarMetrics.utilityHorizontalPadding)
            .padding(.vertical, SidebarMetrics.primaryVerticalPadding)
        }
    }

    private var utilityNavigation: some View {
        VStack(spacing: SidebarMetrics.utilitySpacing) {
            SidebarNavigationButton(
                title: "Usage",
                subtitle: "\(TokenCountFormatter.compact(model.tokenUsage.lastDay)) tokens in 24 hours",
                symbol: "chart.xyaxis.line",
                destination: .usage,
                selection: $selection
            )

            SidebarNavigationButton(
                title: "Settings",
                symbol: "gearshape",
                destination: .settings,
                selection: $selection
            )
        }
        .padding(.horizontal, SidebarMetrics.utilityHorizontalPadding)
        .padding(.vertical, SidebarMetrics.utilityVerticalPadding)
        .accessibilityLabel("Usage and Settings")
    }

    private var llmEndpoints: [APIEndpointConfiguration] {
        model.configuration.endpoints.filter {
            model.isRecognizedLLMEndpoint($0) && !isManagedSubscriptionEndpoint($0)
        }
    }

    private var otherEndpoints: [APIEndpointConfiguration] {
        model.configuration.endpoints.filter { !model.isRecognizedLLMEndpoint($0) }
    }

    private var otherPortForwards: [OtherPortForward] {
        let referencedMappingIDs = Set(model.configuration.endpoints.compactMap { endpoint -> UUID? in
            guard case let .sshMapping(mappingID, _) = endpoint.source else { return nil }
            return mappingID
        })
        return model.configuration.tunnels.flatMap { connection in
            connection.mappings
                .filter { !referencedMappingIDs.contains($0.id) }
                .map { OtherPortForward(connection: connection, mapping: $0) }
        }
    }

    private func endpointRow(_ endpoint: APIEndpointConfiguration) -> some View {
        let readiness = readiness(endpoint)
        return SidebarNavigationButton(
            title: endpoint.name,
            subtitle: "\(sourceSummary(endpoint)), \(readiness.title)",
            symbol: readiness.symbol,
            symbolColor: readinessColor(readiness),
            isMuted: !endpoint.enabled,
            destination: .endpoint(endpoint.id),
            selection: $selection
        )
        .contextMenu {
            Button("Copy URL") {
                if let url = model.endpointURL(endpoint) { model.copy(url.absoluteString) }
            }
            Button("Refresh") { Task { await model.inspectEndpoint(endpoint.id) } }
            if isDirectEndpoint(endpoint) {
                Button("Duplicate API Endpoint") {
                    Task { await model.duplicateEndpoint(endpoint.id) }
                }
            }
            Divider()
            Button("Show in ModelMoor") { selection = .endpoint(endpoint.id) }
        }
    }

    private func connectionRow(_ connection: TunnelConfiguration) -> some View {
        let phase = model.status(for: connection.id).phase
        return SidebarNavigationButton(
            title: connection.name,
            subtitle: connectionSubtitle(connection),
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
            .disabled(
                phase.isConnectionActionPending
                    || (!phase.usesDisconnectAction && connection.enabledMappings.isEmpty)
            )
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

    private func isDirectEndpoint(_ endpoint: APIEndpointConfiguration) -> Bool {
        if case .directHTTPS = endpoint.source { return true }
        if case .managedCLIProxy = endpoint.source { return true }
        return false
    }

    private func isManagedSubscriptionEndpoint(_ endpoint: APIEndpointConfiguration) -> Bool {
        if case .managedCLIProxy = endpoint.source { return true }
        return false
    }

    private func sourceSummary(_ endpoint: APIEndpointConfiguration) -> String {
        switch endpoint.source {
        case let .directHTTPS(origin): return origin.host ?? "Direct HTTPS"
        case .managedCLIProxy: return "Subscription accounts"
        case let .sshMapping(mappingID, _):
            for connection in model.configuration.tunnels where connection.mappings.contains(where: { $0.id == mappingID }) {
                return "via \(connection.name)"
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
        if !model.configuration.gateway.enabled { return "Disabled"
        }
        let count = model.configuration.routes.filter(\.enabled).count
        switch model.gatewayState {
        case .stopped: return "Starting, \(count) models"
        case .running: return count == 1 ? "Ready, 1 model" : "Ready, \(count) models"
        case .failed: return "Needs attention"
        }
    }

    private var subscriptionSubtitle: String {
        if case .failed = model.cliProxyState { return "Needs attention" }
        if model.activeSubscriptionLogin != nil { return "Waiting for sign-in" }
        let total = model.subscriptionAccounts.count
        guard total > 0 else { return "No accounts connected" }
        let active = model.subscriptionAccounts.filter { !$0.disabled }.count
        if total == 1 { return active == 1 ? "1 active account" : "1 disabled account" }
        return "\(active) active of \(total) accounts"
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

    private func connectionSubtitle(_ connection: TunnelConfiguration) -> String {
        let relatedEndpoints = model.configuration.endpoints.filter { endpoint in
            guard case let .sshMapping(mappingID, _) = endpoint.source else { return false }
            return connection.mappings.contains { $0.id == mappingID }
        }
        let endpointCount = relatedEndpoints.filter(model.isRecognizedLLMEndpoint).count
        let otherCount = relatedEndpoints.count - endpointCount
        let status = model.status(for: connection.id).message
        var parts = [status]
        if endpointCount > 0 { parts.append(endpointCount == 1 ? "1 endpoint" : "\(endpointCount) endpoints") }
        if otherCount > 0 { parts.append(otherCount == 1 ? "1 other" : "\(otherCount) others") }
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

private struct OtherPortForward: Identifiable {
    let connection: TunnelConfiguration
    let mapping: PortMappingConfiguration

    var id: UUID { mapping.id }
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

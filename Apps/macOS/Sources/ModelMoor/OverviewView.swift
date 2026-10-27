import ModelMoorApplication
import ModelMoorCore
import ModelMoorSystem
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    let addEndpoint: () -> Void
    @Binding var selection: NavigationSelection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if llmEndpoints.isEmpty {
                    ContentUnavailableView {
                        Label("Connect your first API", systemImage: "link.badge.plus")
                    } description: {
                        Text("Use a remote model over SSH or connect a direct HTTP(S) API. ModelMoor keeps transport details out of the normal workflow.")
                    } actions: {
                        Button("Add API Endpoint…", action: addEndpoint)
                            .buttonStyle(.borderedProminent)
                        Button("Connect Subscription") { selection = .subscriptionAccounts }
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    header
                    readiness
                    quickActions
                    if case let .failed(message) = model.gatewayState {
                        Button { selection = .gateway } label: {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                    }
                    if model.configuration.gateway.enabled || !model.tokenUsage.isEmpty {
                        TokenUsageSummaryView(snapshot: model.tokenUsage)
                    }
                    if !attentionItems.isEmpty { attention }
                    endpoints
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(32)
        }
        .navigationTitle("Overview")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your local model endpoints")
                .font(.title2.weight(.semibold))
            Text("Expose selected models through one authenticated local API.")
                .foregroundStyle(.secondary)
        }
    }

    private var readiness: some View {
        HStack(spacing: 24) {
            Metric(value: "\(readyEndpointCount)", label: "Ready endpoints")
            Divider().frame(height: 42)
            Metric(value: "\(discoveredModelCount)", label: "Discovered models")
            Divider().frame(height: 42)
            Metric(value: gatewayStatus, label: "Unified API")
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var gatewayStatus: String {
        guard model.configuration.gateway.enabled else { return AppLocalization.string("Off") }
        switch model.gatewayState {
        case .running: return AppLocalization.string("Ready")
        case .failed: return AppLocalization.string("Needs Attention")
        case .stopped: return AppLocalization.string("Stopped")
        }
    }

    private var quickActions: some View {
        HStack {
            Button { selection = .gateway } label: {
                Label("Unified API", systemImage: "point.3.connected.trianglepath.dotted")
            }
            Button { selection = .subscriptionAccounts } label: {
                Label("Subscription", systemImage: "person.crop.circle")
            }
            Spacer()
            Button { Task { await model.inspectAllEndpoints() } } label: {
                Label("Refresh Status", systemImage: "arrow.clockwise")
            }
            .disabled(!EndpointInteractionPolicy.canRefreshAll(
                endpoints: model.configuration.endpoints,
                inspectingEndpointIDs: model.inspectingEndpointIDs
            ))
        }
    }

    private var attention: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            ForEach(attentionItems, id: \.id) { item in
                Button {
                    selection = .endpoint(item.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).foregroundStyle(.primary)
                            Text(item.message).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.name)
                .accessibilityValue(item.message)
                .accessibilityHint("Opens API endpoint details")
            }
        }
        .padding(.vertical, 8)
    }

    private var endpoints: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("API endpoints").font(.title2.weight(.semibold))
                Spacer()
                Button("Add Endpoint…", action: addEndpoint)
            }
            ForEach(llmEndpoints) { endpoint in
                Button {
                    selection = .endpoint(endpoint.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: endpointStatus(endpoint).symbol)
                            .foregroundStyle(endpointStatusColor(endpoint))
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(endpoint.name).font(.headline).foregroundStyle(.primary)
                            Text(model.endpointURL(endpoint)?.absoluteString ?? "Invalid endpoint URL")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(endpointStatus(endpoint).title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(endpoint.name)
                .accessibilityValue(
                    "\(endpointStatus(endpoint).title). \(model.endpointURL(endpoint)?.absoluteString ?? "Invalid endpoint URL")"
                )
                .accessibilityHint("Opens API endpoint details")
                Divider()
            }
        }
    }

    private var readyEndpointCount: Int {
        llmEndpoints.filter {
            if case .ready = model.endpointReadiness($0) { return true }
            return false
        }.count
    }

    private var discoveredModelCount: Int {
        llmEndpoints.filter(\.enabled).reduce(0) { $0 + (model.inspections[$1.id]?.models?.count ?? 0) }
    }

    private var attentionItems: [(id: UUID, name: String, message: String)] {
        llmEndpoints.compactMap { endpoint in
            guard case let .needsAttention(message) = model.endpointReadiness(endpoint) else { return nil }
            return (endpoint.id, endpoint.name, message)
        }
    }

    private var llmEndpoints: [APIEndpointConfiguration] {
        model.configuration.endpoints.filter(model.isRecognizedLLMEndpoint)
    }

    private func endpointStatus(_ endpoint: APIEndpointConfiguration) -> EndpointReadiness {
        model.endpointReadiness(endpoint)
    }

    private func endpointStatusColor(_ endpoint: APIEndpointConfiguration) -> Color {
        switch endpointStatus(endpoint) {
        case .disabled: .secondary
        case .ready: .green
        case .needsAttention: .orange
        case .checking: .accentColor
        case .unknown: .secondary
        }
    }
}

private struct Metric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

import ModelMoorCore
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    let addEndpoint: () -> Void
    @Binding var selection: NavigationSelection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if llmEndpoints.isEmpty {
                    ContentUnavailableView {
                        Label("Connect your first API", systemImage: "link.badge.plus")
                    } description: {
                        Text("Use a remote model over SSH or connect a direct HTTPS API. ModelMoor keeps transport details out of the normal workflow.")
                    } actions: {
                        Button("Add API Endpoint…", action: addEndpoint)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    header
                    readiness
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
                .font(.largeTitle.weight(.semibold))
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
            Metric(value: model.configuration.gateway.enabled ? "On" : "Off", label: "Unified API")
            Spacer()
        }
        .padding(.vertical, 4)
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
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
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
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private var readyEndpointCount: Int {
        llmEndpoints.filter { model.inspections[$0.id]?.errorMessage == nil && model.inspections[$0.id]?.statusCode != nil }.count
    }

    private var discoveredModelCount: Int {
        model.inspections.values.compactMap(\.models).reduce(0) { $0 + $1.count }
    }

    private var attentionItems: [(id: UUID, name: String, message: String)] {
        llmEndpoints.compactMap { endpoint in
            guard endpoint.enabled else { return nil }
            guard let message = model.inspections[endpoint.id]?.errorMessage else { return nil }
            return (endpoint.id, endpoint.name, message)
        }
    }

    private var llmEndpoints: [APIEndpointConfiguration] {
        model.configuration.endpoints.filter(model.isRecognizedLLMEndpoint)
    }

    private func endpointStatus(_ endpoint: APIEndpointConfiguration) -> EndpointReadiness {
        if !endpoint.enabled { return .disabled }
        if model.inspectingEndpointIDs.contains(endpoint.id) { return .checking }
        guard let inspection = model.inspections[endpoint.id] else { return .unknown }
        if let message = inspection.errorMessage { return .needsAttention(message) }
        return .ready(inspection.models?.count ?? 0)
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

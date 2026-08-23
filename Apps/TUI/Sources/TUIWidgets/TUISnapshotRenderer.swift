import Foundation
import ModelMoorApplication
import ModelMoorCore
import ModelMoorGateway

/// Renders the non-TTY plain-text snapshot of `modelmoor-tui`. The format is
/// stable for scripts: fixed sections, tab-separated fields, no secrets, no
/// colors, no cursor control.
public enum TUISnapshotRenderer {
    public static func render(snapshot: AppSnapshot, recordedOwner: String?) -> String {
        var lines: [String] = []
        let configuration = snapshot.configuration

        lines.append("ModelMoor snapshot")
        lines.append("runtime\t\(runtimeDescription(snapshot: snapshot, recordedOwner: recordedOwner))")
        lines.append("gateway\t\(gatewayDescription(snapshot.gatewayState))")
        lines.append("usage-24h\t\(snapshot.usage.lastDay) tokens")
        lines.append("subscriptions\t\(configuration.cliProxy.enabled ? "enabled" : "disabled")\t\(snapshot.subscriptions.accounts.count) accounts")

        lines.append("")
        lines.append("[moorings]")
        if configuration.tunnels.isEmpty {
            lines.append("(none)")
        }
        for tunnel in configuration.tunnels {
            let status = snapshot.tunnelStatus(for: tunnel.id)
            lines.append("\(sanitize(tunnel.name))\tssh:\(sanitize(tunnel.sshHost))\t\(status.phase.rawValue)\t\(tunnel.enabledMappings.count) forwards")
        }

        lines.append("")
        lines.append("[endpoints]")
        if configuration.endpoints.isEmpty {
            lines.append("(none)")
        }
        let mappings = Dictionary(
            uniqueKeysWithValues: configuration.tunnels.flatMap(\.mappings).map { ($0.id, $0) }
        )
        for endpoint in configuration.endpoints {
            let inspection = snapshot.inspections[endpoint.id]
            let state: String
            if !EndpointInteractionPolicy.hasRequiredCredential(
                endpoint,
                availableAPIKeyIDs: snapshot.availableEndpointAPIKeyIDs
            ) {
                state = "credential-missing"
            } else if let inspection {
                state = inspection.isReachable
                    ? "reachable(\(inspection.statusCode.map(String.init) ?? "?"))"
                    : "down"
            } else {
                state = "unknown"
            }
            let url = (try? EndpointURLResolver.resolve(endpoint, mappings: mappings).absoluteString) ?? "invalid"
            lines.append("\(sanitize(endpoint.name))\t\(endpoint.kind.rawValue)\t\(state)\t\(url)")
        }

        lines.append("")
        lines.append("[routes]")
        if configuration.routes.isEmpty {
            lines.append("(none)")
        }
        let endpointNames = Dictionary(
            uniqueKeysWithValues: configuration.endpoints.map { ($0.id, $0.name) }
        )
        for route in configuration.routes {
            let endpoint = endpointNames[route.endpointID] ?? "missing"
            lines.append("\(sanitize(route.publicModel))\t-> \(sanitize(endpoint)):\(sanitize(route.upstreamModel))\t\(route.enabled ? "enabled" : "disabled")")
        }
        return lines.joined(separator: "\n")
    }

    /// User-controlled strings (names, hosts, status messages) must not carry
    /// control characters into a terminal or a pipe.
    static func sanitize(_ value: String) -> String {
        String(value.map { character in
            character.isASCII && (character < " " || character == "\u{7F}") ? " " : character
        })
    }

    private static func runtimeDescription(snapshot: AppSnapshot, recordedOwner: String?) -> String {
        switch snapshot.runtimeState {
        case .running:
            return "running (this console owns the runtime)"
        case let .ownedExternally(owner):
            return "owned by \(owner ?? "another process")"
        case .stopped:
            if let recordedOwner {
                return "owned by \(recordedOwner)"
            }
            return "stopped"
        }
    }

    private static func gatewayDescription(_ state: GatewayServiceState) -> String {
        switch state {
        case .stopped: return "stopped"
        case let .running(port): return "running on 127.0.0.1:\(port)"
        case let .failed(message): return "failed: \(message)"
        }
    }
}

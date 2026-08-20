import Foundation
import ModelMoorCore

enum NavigationSelection: Hashable {
    case overview
    case endpoint(UUID)
    case subscriptionAccounts
    case gateway
    case usage
    case settings
    case connection(UUID)
}

enum EndpointSourceChoice: String, CaseIterable, Identifiable {
    case ssh
    case direct

    var id: Self { self }
}

enum EndpointPreset: String, CaseIterable, Identifiable {
    case deepSeek
    case openAI
    case ollama
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .openAI: "OpenAI-compatible"
        case .ollama: "Ollama"
        case .custom: "Custom HTTP"
        }
    }
}

enum EndpointReadiness {
    case disabled
    case unknown
    case checking
    case ready(Int)
    case needsAttention(String)

    var title: String {
        switch self {
        case .disabled: "Disabled"
        case .unknown: "Not checked"
        case .checking: "Checking"
        case let .ready(count): count == 1 ? "Ready, 1 model" : "Ready, \(count) models"
        case let .needsAttention(message): message
        }
    }

    var symbol: String {
        switch self {
        case .disabled: "circle"
        case .unknown: "questionmark.circle"
        case .checking: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }
}

extension TunnelPhase {
    var isConnectionActionPending: Bool {
        self == .disconnecting
    }

    var usesDisconnectAction: Bool {
        switch self {
        case .waitingForNetwork, .connecting, .connected, .waitingToRetry:
            true
        case .stopped, .disconnecting, .failed:
            false
        }
    }

    var connectionActionTitle: String {
        switch self {
        case .stopped: "Connect"
        case .waitingForNetwork, .connected, .waitingToRetry: "Disconnect"
        case .connecting: "Cancel Connection"
        case .disconnecting: "Disconnecting…"
        case .failed: "Retry"
        }
    }

    var canConnect: Bool {
        self == .stopped || self == .failed
    }

    var canDisconnect: Bool {
        switch self {
        case .waitingForNetwork, .connecting, .connected, .waitingToRetry:
            true
        case .stopped, .disconnecting, .failed:
            false
        }
    }
}

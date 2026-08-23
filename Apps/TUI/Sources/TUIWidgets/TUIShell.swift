import Foundation

/// Commands accepted by the one-line command shell at the bottom of the TUI.
/// The parser is intentionally small and deterministic so it can also be used
/// by tests and future non-TermKit front ends.
public enum TUIShellCommand: Equatable, Sendable {
    case help
    case status
    case refresh
    case addSSH
    case addPort
    case addAPI
    case subscriptions
    case subscriptionLogin(provider: String?)
    case subscriptionRefresh
    case subscriptionCancel
    case subscriptionAccounts
    case gateway
    case list
    case filter(String)
    case clearFilter
    case connect(name: String?)
    case disconnect(name: String?)
    case clear
    case quit
    case unknown(String)
}

public enum TUIShellParser {
    public static let helpText = """
    Shell commands
      help, ?              Open the Help pane
      status               Show a compact runtime summary
      refresh              Reload configuration and runtime status
      list                 Open the Settings pane
      filter <terms>       Filter the current SSH, endpoint, or route list
      clear-filter         Clear the current list filter
      add ssh              Add an SSH connection
      add port             Add a local port mapping to an SSH connection
      add api              Add a direct HTTPS API endpoint
      subs                 Configure subscription sign-in and proxy port
      subs login <provider>
                           Start sign-in using codex, claude, antigravity, kimi, or xai
      subs accounts
                           Show subscription accounts and an active sign-in URL
      subs refresh
                           Refresh subscription accounts and proxy health
      subs cancel          Cancel the active subscription sign-in
      gateway              Configure the Unified API listener
      connect [name]       Connect an SSH connection
      disconnect [name]    Disconnect an SSH connection
      clear                Clear the command line status
      quit, exit           Quit ModelMoor

    Press : from any pane to focus this command line.
    """

    public static func parse(_ input: String) -> TUIShellCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = parts.first else { return nil }
        let command = first.lowercased()

        switch command {
        case "help", "?":
            return .help
        case "status":
            return .status
        case "refresh", "reload":
            return .refresh
        case "list", "settings":
            return .list
        case "filter":
            guard let query = remainder(after: parts) else { return .unknown(trimmed) }
            return .filter(query)
        case "clear-filter", "clearfilter":
            return .clearFilter
        case "clear" where parts.dropFirst().first?.lowercased() == "filter":
            return .clearFilter
        case "clear":
            return .clear
        case "quit", "exit":
            return .quit
        case "subs", "subscriptions", "subscription", "sub":
            return parseSubscriptionCommand(parts: parts, original: trimmed)
        case "gateway", "api-gateway":
            return .gateway
        case "connect":
            return .connect(name: remainder(after: parts))
        case "disconnect":
            return .disconnect(name: remainder(after: parts))
        case "add":
            guard parts.count >= 2 else { return .unknown(trimmed) }
            switch parts[1].lowercased() {
            case "ssh", "connection", "connections":
                return .addSSH
            case "port", "mapping", "forward", "forwarding":
                return .addPort
            case "api", "endpoint", "endpoints":
                return .addAPI
            case "subscription", "subscriptions", "sub":
                return .subscriptions
            default:
                return .unknown(trimmed)
            }
        default:
            return .unknown(trimmed)
        }
    }

    private static func remainder(after parts: [String]) -> String? {
        guard parts.count > 1 else { return nil }
        let value = parts.dropFirst().joined(separator: " ")
        return value.isEmpty ? nil : value
    }

    private static func parseSubscriptionCommand(
        parts: [String],
        original: String
    ) -> TUIShellCommand {
        guard parts.count > 1 else { return .subscriptions }
        let action = parts[1].lowercased()
        let provider = parts.dropFirst(2).joined(separator: " ")
        switch action {
        case "login", "sign-in", "signin", "connect":
            return .subscriptionLogin(provider: provider.isEmpty ? nil : provider)
        case "accounts", "account", "list", "status":
            return .subscriptionAccounts
        case "refresh", "reload", "sync":
            return .subscriptionRefresh
        case "cancel", "stop":
            return .subscriptionCancel
        default:
            // A provider immediately after `subs` is a concise
            // login spelling, while other terms remain visible errors.
            if parts.count == 2 {
                return .subscriptionLogin(provider: action)
            }
            return .unknown(original)
        }
    }
}

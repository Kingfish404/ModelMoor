import Foundation
import ModelMoorCore

/// Presentation-independent eligibility for endpoint commands. GUI and TUI
/// surfaces use these rules both to advertise commands and to guard their
/// handlers when state changes between rendering and activation.
public enum EndpointInteractionPolicy {
    public static func canCopyURL(_ resolvedURL: URL?) -> Bool {
        resolvedURL != nil
    }

    public static func canRefresh(
        _ endpoint: APIEndpointConfiguration,
        inspectingEndpointIDs: Set<UUID>
    ) -> Bool {
        endpoint.enabled && !inspectingEndpointIDs.contains(endpoint.id)
    }

    public static func canDuplicate(_ endpoint: APIEndpointConfiguration) -> Bool {
        if case .directHTTPS = endpoint.source { return true }
        return false
    }

    public static func canRefreshAll(
        endpoints: [APIEndpointConfiguration],
        inspectingEndpointIDs: Set<UUID>
    ) -> Bool {
        endpoints.contains(where: \.enabled) && inspectingEndpointIDs.isEmpty
    }

    /// Secret-free credential readiness shared by GUI and TUI. Presentations
    /// only receive key IDs known to have a stored value, never the value.
    public static func hasRequiredCredential(
        _ endpoint: APIEndpointConfiguration,
        availableAPIKeyIDs: Set<UUID>
    ) -> Bool {
        guard endpoint.authentication != .none else { return true }
        guard let keyID = endpoint.activeAPIKeyID else { return false }
        return availableAPIKeyIDs.contains(keyID)
    }
}

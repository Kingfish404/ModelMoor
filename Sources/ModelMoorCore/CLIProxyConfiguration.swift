import Foundation

public struct CLIProxyConfiguration: Codable, Equatable, Sendable {
    public static let defaultEndpointID = UUID(uuidString: "8EC690A4-A9B2-4BC1-B0BB-A2DF5298806E")!

    public var enabled: Bool
    public var listenPort: Int
    public var endpointID: UUID

    public init(
        enabled: Bool = false,
        listenPort: Int = 18_317,
        endpointID: UUID = defaultEndpointID
    ) {
        self.enabled = enabled
        self.listenPort = listenPort
        self.endpointID = endpointID
    }

    public func validated() throws -> Self {
        guard (1_024...65_535).contains(listenPort) else {
            throw ConfigurationError.invalidValue("Subscription proxy port must be between 1024 and 65535.")
        }
        return self
    }
}

public extension ModelMoorConfiguration {
    mutating func reconcileManagedCLIProxyEndpoint() {
        guard cliProxy.enabled else { return }
        let managed = APIEndpointConfiguration.managedCLIProxy(
            id: cliProxy.endpointID,
            port: cliProxy.listenPort
        )
        if let index = endpoints.firstIndex(where: { $0.id == cliProxy.endpointID }) {
            let existingName = endpoints[index].name
            endpoints[index] = managed
            if !existingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                endpoints[index].name = existingName
            }
        } else {
            endpoints.append(managed)
        }
    }
}

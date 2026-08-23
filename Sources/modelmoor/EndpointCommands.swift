import ArgumentParser
import Foundation
import ModelMoorCore
import ModelMoorSystem

struct ProbeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe",
        abstract: "Probe endpoint reachability and model lists."
    )

    @Argument(help: "Endpoint name (default: all enabled endpoints)")
    var name: String?

    func run() async throws {
        let configuration = try await CLISupport.store().load()
        let endpoints: [APIEndpointConfiguration]
        if let name {
            endpoints = [try CLISupport.singleEndpoint(name, configuration: configuration)]
        } else {
            endpoints = configuration.endpoints.filter(\.enabled)
        }
        let inspector = APIInspector()
        let secretStore = try SecretStoreResolver.defaultStore()
        let mappings = CLISupport.mappingIndex(configuration)
        var failed = false
        for endpoint in endpoints {
            let secret = CLISupport.endpointSecret(for: endpoint, secretStore: secretStore)
            let inspection = await inspector.inspect(endpoint, mappings: mappings, secret: secret)
            let state = inspection.isReachable ? "ok" : "down"
            let models = inspection.models.map { "\($0.count) models" } ?? (inspection.errorMessage ?? "no model metadata")
            print("\(state)\t\(endpoint.name)\t\(inspection.url?.absoluteString ?? "-")\t\(models)")
            failed = failed || !inspection.isReachable
        }
        if failed { throw CLIError("One or more APIs are unreachable.") }
    }
}

struct EndpointCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "endpoint",
        abstract: "Inspect configured API endpoints.",
        subcommands: [EndpointListCommand.self, EndpointURLCommand.self, EndpointModelsCommand.self],
        defaultSubcommand: EndpointListCommand.self
    )
}

struct EndpointListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List endpoints.")

    func run() async throws {
        let configuration = try await CLISupport.store().load()
        let mappings = CLISupport.mappingIndex(configuration)
        for endpoint in configuration.endpoints {
            let marker = endpoint.enabled ? "*" : "o"
            let url = (try? EndpointURLResolver.resolve(endpoint, mappings: mappings).absoluteString) ?? "invalid"
            print("\(marker) \(endpoint.name)\t\(endpoint.kind.rawValue)\t\(url)")
        }
    }
}

struct EndpointURLCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "url", abstract: "Print an endpoint's resolved URL.")

    @Argument(help: "Endpoint name") var name: String

    func run() async throws {
        try await CLISupport.printEndpointURL(named: name)
    }
}

struct EndpointModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "models", abstract: "Print an endpoint's model IDs.")

    @Argument(help: "Endpoint name") var name: String

    func run() async throws {
        try await CLISupport.printEndpointModels(named: name)
    }
}

struct URLCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "url",
        abstract: "Print an endpoint's resolved URL."
    )

    @Argument(help: "Endpoint name") var name: String

    func run() async throws {
        try await CLISupport.printEndpointURL(named: name)
    }
}

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Print an endpoint's model IDs."
    )

    @Argument(help: "Endpoint name") var name: String

    func run() async throws {
        try await CLISupport.printEndpointModels(named: name)
    }
}

struct RouteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "route",
        abstract: "Inspect Unified API model routes.",
        subcommands: [RouteListCommand.self],
        defaultSubcommand: RouteListCommand.self
    )
}

struct RouteListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List model routes.")

    func run() async throws {
        let configuration = try await CLISupport.store().load()
        for route in configuration.routes {
            let marker = route.enabled ? "*" : "o"
            let endpoint = configuration.endpoints.first(where: { $0.id == route.endpointID })?.name ?? "missing"
            print("\(marker) \(route.publicModel)\t-> \(endpoint):\(route.upstreamModel)")
        }
    }
}

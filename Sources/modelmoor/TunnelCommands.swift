import ArgumentParser
import Foundation
import ModelMoorApplication
import ModelMoorCore
import ModelMoorGateway
import ModelMoorSystem

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create the first mooring for SSH_HOST."
    )

    @Argument(help: "SSH host alias or hostname")
    var sshHost: String

    @OptionGroup var mapping: TunnelMappingOptions

    func run() async throws {
        let store = CLISupport.store()
        let existing = try await store.load()
        guard existing.tunnels.isEmpty else {
            throw CLIError("Configuration already contains tunnels. Use `modelmoor add`.")
        }
        let tunnel = try mapping.makeTunnel(
            name: mapping.name ?? CLISupport.defaultName(for: sshHost),
            sshHost: sshHost
        )
        let endpoint = try mapping.makeEndpoint(for: tunnel)
        try await store.save(ModelMoorConfiguration(
            tunnels: [tunnel],
            endpoints: endpoint.map { [$0] } ?? []
        ))
        CLISupport.printCreated(tunnel, path: await store.fileURL.path)
    }
}

struct AddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a mooring for SSH_HOST."
    )

    @Argument(help: "Mooring name") var name: String
    @Argument(help: "SSH host alias or hostname") var sshHost: String

    @OptionGroup var mapping: TunnelMappingOptions

    func run() async throws {
        let store = CLISupport.store()
        var configuration = try await store.load()
        let tunnel = try mapping.makeTunnel(name: name, sshHost: sshHost)
        let endpoint = try mapping.makeEndpoint(for: tunnel)
        configuration.tunnels.append(tunnel)
        if let endpoint { configuration.endpoints.append(endpoint) }
        try await store.save(configuration)
        CLISupport.printCreated(tunnel, path: await store.fileURL.path)
    }
}

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List moorings and their port forwards."
    )

    func run() async throws {
        let configuration = try await CLISupport.store().load()
        if configuration.tunnels.isEmpty {
            print("No tunnels configured. Run `modelmoor init SSH_HOST`.")
        } else {
            for tunnel in configuration.tunnels {
                let marker = tunnel.connectOnLaunch ? "*" : "o"
                print("\(marker) \(tunnel.name)\tssh:\(tunnel.sshHost)\t\(tunnel.enabledMappings.count) forwards")
                for mapping in tunnel.mappings {
                    let mappingMarker = mapping.enabled ? "  *" : "  o"
                    print("\(mappingMarker) \(mapping.name)\t\(mapping.direction.sshFlag) \(mapping.forwardingSpecification)")
                }
            }
        }
    }
}

struct RemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a mooring and cascade-delete its endpoints, routes and keys."
    )

    @Argument(help: "Mooring name") var name: String

    func run() async throws {
        let store = CLISupport.store()
        let configuration = try await store.load()
        guard let tunnel = configuration.tunnels.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { throw CLIError("Tunnel not found: \(name)") }
        let result = try await ConfigurationDeletionCoordinator(
            store: store,
            secretStore: SecretStoreResolver.defaultStore()
        ).removeTunnel(tunnel.id, from: configuration)
        print("Removed \(name), \(result.removedEndpointIDs.count) endpoint(s), and \(result.removedRouteIDs.count) route(s)")
    }
}

struct EnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Start a mooring automatically when the runtime starts."
    )

    @Argument(help: "Mooring name") var name: String

    func run() async throws {
        try await mutate { $0.connectOnLaunch = true }
    }

    private func mutate(_ mutation: (inout TunnelConfiguration) -> Void) async throws {
        let store = CLISupport.store()
        var configuration = try await store.load()
        guard let index = configuration.tunnels.firstIndex(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { throw CLIError("Tunnel not found: \(name)") }
        mutation(&configuration.tunnels[index])
        try await store.save(configuration)
        print("Updated \(name)")
    }
}

struct DisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Do not start a mooring automatically."
    )

    @Argument(help: "Mooring name") var name: String

    func run() async throws {
        let store = CLISupport.store()
        var configuration = try await store.load()
        guard let index = configuration.tunnels.firstIndex(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { throw CLIError("Tunnel not found: \(name)") }
        configuration.tunnels[index].connectOnLaunch = false
        try await store.save(configuration)
        print("Updated \(name)")
    }
}

struct SSHCommandCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh-command",
        abstract: "Print the exact ssh master/forward commands for debugging."
    )

    @Argument(help: "Mooring name (default: all)") var name: String?

    func run() async throws {
        let configuration = try await CLISupport.store().load()
        let selected: [TunnelConfiguration]
        if let name {
            selected = configuration.tunnels.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            guard !selected.isEmpty else { throw CLIError("Tunnel not found: \(name)") }
        } else {
            selected = configuration.tunnels
        }
        for tunnel in selected {
            let builder = SSHCommandBuilder()
            let commands = [
                ("master", builder.command(for: tunnel)),
                ("forward", builder.controlCommand(.forward, for: tunnel))
            ]
            for (label, built) in commands {
                let rendered = ([built.executableURL.path] + built.arguments)
                    .map(CLISupport.shellQuoted)
                    .joined(separator: " ")
                print("\(label)\t\(rendered)")
            }
        }
    }
}

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the runtime in the foreground: moorings plus the Unified API."
    )

    @Argument(help: "Mooring name (default: all connect-on-launch moorings)")
    var name: String?

    func run() async throws {
        let session = try ModelMoorSession(profile: .current)
        try await session.load()
        let loaded = await session.snapshot
        let selected: [TunnelConfiguration]
        if let name {
            selected = loaded.configuration.tunnels.filter {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
            guard !selected.isEmpty else { throw CLIError("Tunnel not found: \(name)") }
        } else {
            selected = loaded.configuration.tunnels.filter(\.connectOnLaunch)
        }
        guard !selected.isEmpty || loaded.configuration.gateway.enabled else {
            throw CLIError("No moorings or Local Gateway are enabled for startup.")
        }
        try await session.startRuntime(
            owner: "modelmoor run",
            tunnelIDs: Set(selected.map(\.id))
        )
        let started = await session.snapshot
        if started.configuration.gateway.enabled,
           case let .failed(message) = started.gatewayState {
            await session.stopRuntime()
            throw CLIError(message)
        }
        let printer = Task {
            var seen: [UUID: TunnelStatus] = [:]
            var gatewayReadyPrinted = false
            for await update in session.snapshots() {
                for (id, status) in update.tunnelStatuses where seen[id] != status {
                    seen[id] = status
                    guard let tunnel = update.configuration.tunnels.first(where: { $0.id == id }) else { continue }
                    print("[\(tunnel.name)] \(status.phase.rawValue): \(status.message)")
                }
                if !gatewayReadyPrinted, case let .running(port) = update.gatewayState {
                    gatewayReadyPrinted = true
                    print("Gateway ready at http://127.0.0.1:\(port)/v1")
                }
            }
        }
        await ProcessTerminationSignal.wait {
            print("ModelMoor is running. Press Ctrl-C to stop.")
        }
        printer.cancel()
        await session.stopRuntime()
    }
}

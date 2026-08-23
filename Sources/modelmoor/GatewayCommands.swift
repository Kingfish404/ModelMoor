import ArgumentParser
import Foundation
import ModelMoorCore
import ModelMoorSystem

struct GatewayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gateway",
        abstract: "Inspect the Unified API listener.",
        subcommands: [GatewayURLCommand.self, GatewayStatusCommand.self, GatewayTokenCommand.self],
        defaultSubcommand: GatewayStatusCommand.self
    )
}

struct GatewayURLCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "url", abstract: "Print the Unified API base URL.")

    func run() async throws {
        let configuration = try await CLISupport.store().load()
        print("http://127.0.0.1:\(configuration.gateway.listenPort)/v1")
    }
}

struct GatewayStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Print the Unified API status.")

    func run() async throws {
        let configuration = try await CLISupport.store().load()
        print(configuration.gateway.enabled
            ? "enabled\t127.0.0.1:\(configuration.gateway.listenPort)"
            : "disabled")
    }
}

struct GatewayTokenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "token",
        abstract: "Copy the first Unified API key to the clipboard."
    )

    @Flag(help: "Copy the key to the clipboard")
    var copy = false

    func run() async throws {
        guard copy else {
            throw CLIError("Usage: modelmoor gateway token --copy")
        }
        let configuration = try await CLISupport.store().load()
        guard let key = configuration.gateway.apiKeys.first(where: \.enabled)
                ?? configuration.gateway.apiKeys.first else {
            throw CLIError("No Unified API key is configured.")
        }
        let secretStore = try SecretStoreResolver.defaultStore()
        try CLISupport.copyToClipboard(secretStore.ensureGatewayAPIKey(for: key.id))
        print("Copied the Unified API key to the pasteboard.")
    }
}

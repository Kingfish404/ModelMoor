import ArgumentParser
import Foundation
import ModelMoorTUI

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct ModelMoorCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "modelmoor",
        abstract: "Remote and commercial models, one local API.",
        subcommands: [
            InitCommand.self,
            AddCommand.self,
            ListCommand.self,
            RemoveCommand.self,
            EnableCommand.self,
            DisableCommand.self,
            ProbeCommand.self,
            EndpointCommand.self,
            URLCommand.self,
            ModelsCommand.self,
            RouteCommand.self,
            GatewayCommand.self,
            SSHCommandCommand.self,
            RunCommand.self,
            DoctorCommand.self,
            ConfigPathCommand.self
        ]
    )

    func run() async throws {
        ModelMoorTUIEntryPoint.run()
    }
}

/// ArgumentParser's async command runner owns a cooperative executor. TermKit
/// owns the terminal main loop synchronously, so launch the no-argument TUI
/// before entering ArgumentParser's async runtime. Top-level help is emitted
/// synchronously, while explicit commands retain ArgumentParser behavior.
@main
struct ModelMoorMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 1, ["-h", "--help"].contains(arguments[0]) {
            // Help is a synchronous, complete stdout document. Do not route it
            // through the detached async command runner used by subcommands.
            let text = ModelMoorCLI.helpMessage() + "\n"
            FileHandle.standardOutput.write(Data(text.utf8))
        } else if arguments.isEmpty {
            ModelMoorTUIEntryPoint.run()
        } else {
            let completed = DispatchSemaphore(value: 0)
            Task.detached {
                await ModelMoorCLI.main()
                completed.signal()
            }
            completed.wait()
        }
    }
}

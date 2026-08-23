import ArgumentParser
import Foundation
import ModelMoorApplication
import ModelMoorCore

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Read-only diagnostics: configuration, OpenSSH, transports, endpoints, Unified API."
    )

    func run() async throws {
        let report = await DoctorRunner(profile: .current).run()
        for finding in report.findings {
            print("\(finding.severity.rawValue)\t\(finding.check)\t\(finding.detail)")
            if let suggestion = finding.suggestion, finding.severity != .ok {
                FileHandle.standardError.write(Data("  suggestion: \(suggestion)\n".utf8))
            }
        }
        // Stable exit classification (docs/PLAN.md milestone B):
        // 0 healthy, 10 config, 20 system, 30 SSH transport,
        // 40 endpoint auth, 50 API/protocol, 60 Gateway.
        let code = report.exitCode
        if code != 0 {
            throw ExitCode(code)
        }
    }
}

struct ConfigPathCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config-path",
        abstract: "Print the configuration file path."
    )

    func run() async throws {
        print(CLISupport.configurationFilePath)
    }
}

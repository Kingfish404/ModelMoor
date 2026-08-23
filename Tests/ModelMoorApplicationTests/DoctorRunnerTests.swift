import Foundation
import XCTest
@testable import ModelMoorApplication
@testable import ModelMoorSystem
import ModelMoorCore

/// Layer/exit-code determinism for `modelmoor doctor`. All checks run against
/// temporary directories, injected secret stores and stubbed SSH/HTTP probes —
/// no user Keychain, no real SSH connections, no listeners.
final class DoctorRunnerTests: XCTestCase {
    private struct StubInspector: APIInspecting {
        let results: [UUID: EndpointInspection]

        func inspect(
            _ endpoint: APIEndpointConfiguration,
            mappings: [UUID: PortMappingConfiguration],
            secret: String?
        ) async -> EndpointInspection {
            results[endpoint.id] ?? EndpointInspection(
                endpointID: endpoint.id,
                url: nil,
                errorMessage: "unreachable"
            )
        }
    }

    private func makeEnvironment(
        _ name: String = UUID().uuidString
    ) throws -> (ConfigurationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoctorRunnerTests-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigurationStore(
            fileURL: directory.appendingPathComponent("config.json"),
            endpointCredentialLookup: { _ in nil }
        )
        return (store, directory)
    }

    private func makeRunner(
        store: ConfigurationStore,
        directory: URL,
        inspections: [UUID: EndpointInspection] = [:],
        batchModeStatus: Int32 = 0
    ) -> DoctorRunner {
        let profile = ModelMoorRuntimeProfile.make(
            .development,
            homeDirectory: directory,
            configurationHome: directory
        )
        return DoctorRunner(
            store: store,
            profile: profile,
            secretStoreResolver: {
                HeadlessFileSecretStore(fileURL: directory.appendingPathComponent("secrets.json"))
            },
            inspector: StubInspector(results: inspections),
            sshExecutable: URL(fileURLWithPath: "/usr/bin/ssh"),
            batchModeProbe: { _ in (batchModeStatus, batchModeStatus == 0 ? "" : "Permission denied (publickey).") }
        )
    }

    func testHealthyConfigurationWithoutTunnelsExitsZero() async throws {
        let (store, directory) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(ModelMoorConfiguration())

        let report = await makeRunner(store: store, directory: directory).run()
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertTrue(report.findings.contains {
            $0.layer == .configuration && $0.severity == .ok
        })
    }

    func testUnreadableConfigurationFailsLayerTen() async throws {
        let (store, directory) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(ModelMoorConfiguration())
        try Data("not json".utf8).write(to: directory.appendingPathComponent("config.json"))

        let report = await makeRunner(store: store, directory: directory).run()
        XCTAssertEqual(report.exitCode, 10)
        XCTAssertTrue(report.findings.contains {
            $0.layer == .configuration && $0.severity == .fail
        })
    }

    func testBatchModeFailureExitsThirty() async throws {
        let (store, directory) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tunnel = TunnelConfiguration(
            name: "lab",
            sshHost: "lab.example",
            connectOnLaunch: true
        )
        try await store.save(ModelMoorConfiguration(tunnels: [tunnel]))

        let report = await makeRunner(store: store, directory: directory, batchModeStatus: 255).run()
        XCTAssertEqual(report.exitCode, 30)
        XCTAssertTrue(report.findings.contains {
            $0.layer == .sshTransport && $0.severity == .fail
        })
    }

    func testEndpointAuthFailureExitsForty() async throws {
        let (store, directory) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = APIEndpointConfiguration(
            name: "Cloud",
            source: .directHTTPS(originURL: URL(string: "https://api.example.com")!),
            modelListPath: "/v1/models",
            authentication: .bearer
        )
        try await store.save(ModelMoorConfiguration(endpoints: [endpoint]))
        let inspection = EndpointInspection(
            endpointID: endpoint.id,
            url: URL(string: "https://api.example.com/v1/models"),
            statusCode: 401,
            errorMessage: "Authentication required"
        )

        let report = await makeRunner(
            store: store,
            directory: directory,
            inspections: [endpoint.id: inspection]
        ).run()
        XCTAssertEqual(report.exitCode, 40)
        XCTAssertTrue(report.findings.contains {
            $0.layer == .endpointAuth && $0.severity == .fail
        })
    }

    func testIncompatibleModelListExitsFifty() async throws {
        let (store, directory) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = APIEndpointConfiguration(
            name: "Odd",
            source: .directHTTPS(originURL: URL(string: "https://api.example.com")!),
            modelListPath: "/v1/models"
        )
        try await store.save(ModelMoorConfiguration(endpoints: [endpoint]))
        let inspection = EndpointInspection(
            endpointID: endpoint.id,
            url: URL(string: "https://api.example.com/v1/models"),
            statusCode: 200,
            errorMessage: "The endpoint is reachable, but its model list is incompatible"
        )

        let report = await makeRunner(
            store: store,
            directory: directory,
            inspections: [endpoint.id: inspection]
        ).run()
        XCTAssertEqual(report.exitCode, 50)
    }

    func testReportNeverContainsSecrets() async throws {
        let (store, directory) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(ModelMoorConfiguration())

        let runner = makeRunner(store: store, directory: directory)
        let secretStore = HeadlessFileSecretStore(
            fileURL: directory.appendingPathComponent("secrets.json")
        )
        try secretStore.setToken("sk-unit-test-secret", for: UUID())
        let report = await runner.run()
        let rendered = report.findings
            .map { "\($0.check) \($0.detail) \($0.suggestion ?? "")" }
            .joined(separator: "\n")
        XCTAssertFalse(rendered.contains("sk-unit-test-secret"))
    }
}

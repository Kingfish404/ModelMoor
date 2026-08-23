import ModelMoorCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public actor ConfigurationStore {
    public typealias EndpointCredentialLookup = @Sendable (UUID) throws -> String?

    public let fileURL: URL
    public let legacyImportURL: URL?
    private let endpointCredentialLookup: EndpointCredentialLookup
    private let initialConfiguration: ModelMoorConfiguration
    /// Revision of the configuration this store's clients last loaded or
    /// wrote. Cross-process compare-and-swap state lives in a sidecar file
    /// (`config.json.revision`) so config.json itself stays byte-compatible
    /// with older versions (docs/PLAN.md milestone B rollback rule).
    private var lastKnownRevision = 0

    public init(
        fileURL: URL = ConfigurationStore.defaultURL(),
        legacyImportURL: URL? = nil,
        initialConfiguration: ModelMoorConfiguration = ModelMoorConfiguration(
            hasPreparedRecommendedEndpoints: false
        ),
        endpointCredentialLookup: @escaping EndpointCredentialLookup = {
            try SecretStoreResolver.defaultStore().token(for: $0)
        }
    ) {
        self.fileURL = fileURL
        self.legacyImportURL = legacyImportURL
        self.initialConfiguration = initialConfiguration
        self.endpointCredentialLookup = endpointCredentialLookup
    }

    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = ModelMoorRuntimeProfile.configurationOverrideURL(environment: environment) {
            return override
        }
        return ModelMoorRuntimeProfile.configurationHome(
            environment: environment,
            homeDirectory: homeDirectory
        )
        .appendingPathComponent("modelmoor", isDirectory: true)
        .appendingPathComponent("config.json")
    }

    public static func defaultLegacyImportURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        guard PlatformPaths.hasLegacyConfigurationLayout else { return nil }
        guard ModelMoorRuntimeProfile.configurationOverrideURL(environment: environment) == nil else {
            return nil
        }
        return homeDirectory
            .appendingPathComponent("Library/Application Support/ModelMoor", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public func load() throws -> ModelMoorConfiguration {
        try withConfigurationLock {
            try importLegacyConfigurationIfNeeded()
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                let initial = preparedRecommendedEndpoints(in: initialConfiguration)
                try prepareDirectory()
                try persistLocked(initial)
                return initial
            }
            let data = try readConfigurationData()
            let schema = try decodeSchema(from: data)
            let result: ModelMoorConfiguration
            switch schema {
            case ModelMoorConfiguration.currentSchemaVersion:
                do {
                    let decoded = try JSONDecoder().decode(ModelMoorConfiguration.self, from: data).validated()
                    let repaired = preparedRecommendedEndpoints(
                        in: repairLegacyAuthentication(in: decoded)
                    )
                    if repaired != decoded { try persistLocked(repaired) }
                    result = repaired
                } catch let error as ConfigurationError {
                    throw error
                } catch {
                    throw ConfigurationError.unreadable("Could not decode configuration: \(error.localizedDescription)")
                }
            case 2:
                result = try migrateV2(data)
            case 1:
                result = try migrateV1(data)
            default:
                throw ConfigurationError.unsupportedSchema(schema)
            }
            lastKnownRevision = readRevisionLocked()
            return result
        }
    }

    public func save(_ configuration: ModelMoorConfiguration) throws {
        try withConfigurationLock {
            let validated = try configuration.validated()
            try prepareDirectory()

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let existing = try readConfigurationData()
                let schema = try decodeSchema(from: existing)
                if schema == 2 {
                    _ = try migrateV2(existing)
                } else if schema == 1 {
                    _ = try migrateV1(existing)
                } else if schema != ModelMoorConfiguration.currentSchemaVersion {
                    throw ConfigurationError.unsupportedSchema(schema)
                }
            }
            // Compare-and-swap: a writer may never overwrite a configuration
            // whose on-disk revision is ahead of the revision it based its
            // edit on. Migration writes above count as this process's own.
            let onDisk = readRevisionLocked()
            guard onDisk <= lastKnownRevision else {
                throw ConfigurationError.revisionConflict(onDisk: onDisk, basedOn: lastKnownRevision)
            }
            try persistLocked(validated)
        }
    }

    private var v1BackupURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).v1.backup")
    }

    private func importLegacyConfigurationIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: fileURL.path),
              let legacyImportURL,
              legacyImportURL.standardizedFileURL != fileURL.standardizedFileURL,
              FileManager.default.fileExists(atPath: legacyImportURL.path) else { return }
        let legacyData: Data
        do {
            legacyData = try Data(contentsOf: legacyImportURL, options: [.mappedIfSafe])
        } catch {
            throw ConfigurationError.unreadable(
                "Could not import the legacy configuration: \(error.localizedDescription)"
            )
        }
        try prepareDirectory()
        try DurableAtomicWriter.writeAtomically(legacyData, to: fileURL, replacing: false)
        try bumpRevisionLocked()
    }

    private var v2BackupURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).v2.backup")
    }

    private func migrateV2(_ data: Data) throws -> ModelMoorConfiguration {
        let migrated = try ConfigurationMigration.migrateV2(data)
        let prepared = preparedRecommendedEndpoints(in: migrated)
        try prepareDirectory()
        if !FileManager.default.fileExists(atPath: v2BackupURL.path) {
            try DurableAtomicWriter.writeAtomically(data, to: v2BackupURL, replacing: false)
        }
        try persistLocked(prepared)
        return prepared
    }

    private func migrateV1(_ data: Data) throws -> ModelMoorConfiguration {
        let migrated = try ConfigurationMigration.migrateV1(
            data,
            endpointHasCredential: legacyEndpointHasCredential
        )
        let prepared = preparedRecommendedEndpoints(in: migrated)
        try prepareDirectory()
        if !FileManager.default.fileExists(atPath: v1BackupURL.path) {
            try DurableAtomicWriter.writeAtomically(data, to: v1BackupURL, replacing: false)
        }
        try persistLocked(prepared)
        return prepared
    }

    private func repairLegacyAuthentication(
        in configuration: ModelMoorConfiguration
    ) -> ModelMoorConfiguration {
        var repaired = configuration
        for index in repaired.endpoints.indices {
            let endpoint = repaired.endpoints[index]
            guard case let .sshMapping(mappingID, _) = endpoint.source,
                  mappingID == endpoint.id,
                  endpoint.authentication == .bearer else { continue }
            do {
                if try endpointCredentialLookup(endpoint.id)?.isEmpty != false {
                    repaired.endpoints[index].authentication = .none
                }
            } catch {
                // Keep authentication unchanged when Keychain availability is uncertain.
            }
        }
        return repaired
    }

    private func preparedRecommendedEndpoints(
        in configuration: ModelMoorConfiguration
    ) -> ModelMoorConfiguration {
        guard !configuration.hasPreparedRecommendedEndpoints else { return configuration }
        var prepared = configuration
        for preset in APIEndpointConfiguration.recommendedCloudEndpoints {
            guard !prepared.endpoints.contains(where: { isEquivalentDirectEndpoint($0, to: preset) }) else {
                continue
            }
            var endpoint = preset
            endpoint.name = uniqueEndpointName(endpoint.name, in: prepared.endpoints)
            prepared.endpoints.append(endpoint)
        }
        prepared.hasPreparedRecommendedEndpoints = true
        return prepared
    }

    private func isEquivalentDirectEndpoint(
        _ endpoint: APIEndpointConfiguration,
        to preset: APIEndpointConfiguration
    ) -> Bool {
        guard case let .directHTTPS(origin) = endpoint.source,
              case let .directHTTPS(presetOrigin) = preset.source else { return false }
        return origin.absoluteString.caseInsensitiveCompare(presetOrigin.absoluteString) == .orderedSame
            && endpoint.basePath.caseInsensitiveCompare(preset.basePath) == .orderedSame
    }

    private func uniqueEndpointName(
        _ desiredName: String,
        in endpoints: [APIEndpointConfiguration]
    ) -> String {
        let names = Set(endpoints.map { $0.name.lowercased() })
        guard names.contains(desiredName.lowercased()) else { return desiredName }
        var suffix = 2
        while names.contains("\(desiredName) \(suffix)".lowercased()) { suffix += 1 }
        return "\(desiredName) \(suffix)"
    }

    private func legacyEndpointHasCredential(_ endpointID: UUID) -> Bool {
        do {
            return try endpointCredentialLookup(endpointID)?.isEmpty == false
        } catch {
            // Conservatively preserve authentication if Keychain cannot be queried.
            return true
        }
    }

    // MARK: - Cross-process lock and revision

    private var lockFileURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).lock")
    }

    private var revisionFileURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).revision")
    }

    /// Serializes load/save across processes with a blocking flock. Held only
    /// for the duration of one read-modify-write; never waits on network or
    /// user interaction while held.
    private func withConfigurationLock<T>(_ body: () throws -> T) throws -> T {
        try prepareDirectory()
        let descriptor = open(lockFileURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ConfigurationError.unreadable(
                "Could not open the configuration lock: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw ConfigurationError.unreadable(
                "Could not lock the configuration: \(String(cString: strerror(errno)))"
            )
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func readRevisionLocked() -> Int {
        guard let data = try? Data(contentsOf: revisionFileURL),
              let value = Int(String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)),
              value >= 0 else { return 0 }
        return value
    }

    @discardableResult
    private func bumpRevisionLocked() throws -> Int {
        let revision = readRevisionLocked() + 1
        try DurableAtomicWriter.writeAtomically(
            Data("\(revision)\n".utf8),
            to: revisionFileURL,
            replacing: true
        )
        return revision
    }

    private func persistLocked(_ configuration: ModelMoorConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        // Bump the revision FIRST: a crash between the two writes then fails
        // safe (spurious conflict) instead of allowing a lost update.
        try bumpRevisionLocked()
        try DurableAtomicWriter.writeAtomically(data, to: fileURL, replacing: true)
        lastKnownRevision = readRevisionLocked()
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func readConfigurationData() throws -> Data {
        do {
            return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw ConfigurationError.unreadable("Could not read configuration: \(error.localizedDescription)")
        }
    }

    private func decodeSchema(from data: Data) throws -> Int {
        do {
            return try JSONDecoder().decode(SchemaEnvelope.self, from: data).schemaVersion
        } catch {
            throw ConfigurationError.unreadable("Configuration is missing a valid schemaVersion: \(error.localizedDescription)")
        }
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }
}

import Darwin
import Foundation

public actor ConfigurationStore {
    public typealias EndpointCredentialLookup = @Sendable (UUID) throws -> String?

    public let fileURL: URL
    private let endpointCredentialLookup: EndpointCredentialLookup

    public init(
        fileURL: URL = ConfigurationStore.defaultURL(),
        endpointCredentialLookup: @escaping EndpointCredentialLookup = {
            try KeychainTokenStore().token(for: $0)
        }
    ) {
        self.fileURL = fileURL
        self.endpointCredentialLookup = endpointCredentialLookup
    }

    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["MODELMOOR_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ModelMoor", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public func load() throws -> ModelMoorConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let initial = preparedRecommendedEndpoints(in: ModelMoorConfiguration(
                hasPreparedRecommendedEndpoints: false
            ))
            try prepareDirectory()
            try persist(initial)
            return initial
        }
        let data = try readConfigurationData()
        let schema = try decodeSchema(from: data)
        switch schema {
        case ModelMoorConfiguration.currentSchemaVersion:
            do {
                let decoded = try JSONDecoder().decode(ModelMoorConfiguration.self, from: data).validated()
                let repaired = preparedRecommendedEndpoints(
                    in: repairLegacyAuthentication(in: decoded)
                )
                if repaired != decoded { try persist(repaired) }
                return repaired
            } catch let error as ConfigurationError {
                throw error
            } catch {
                throw ConfigurationError.unreadable("Could not decode configuration: \(error.localizedDescription)")
            }
        case 1:
            return try migrateV1(data)
        default:
            throw ConfigurationError.unsupportedSchema(schema)
        }
    }

    public func save(_ configuration: ModelMoorConfiguration) throws {
        let validated = try configuration.validated()
        try prepareDirectory()

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let existing = try readConfigurationData()
            let schema = try decodeSchema(from: existing)
            if schema == 1 {
                _ = try migrateV1(existing)
            } else if schema != ModelMoorConfiguration.currentSchemaVersion {
                throw ConfigurationError.unsupportedSchema(schema)
            }
        }
        try persist(validated)
    }

    private var v1BackupURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).v1.backup")
    }

    private func migrateV1(_ data: Data) throws -> ModelMoorConfiguration {
        let migrated = try ConfigurationMigration.migrateV1(
            data,
            endpointHasCredential: legacyEndpointHasCredential
        )
        let prepared = preparedRecommendedEndpoints(in: migrated)
        try prepareDirectory()
        if !FileManager.default.fileExists(atPath: v1BackupURL.path) {
            try DurableAtomicWriter.write(data, to: v1BackupURL, replacing: false)
        }
        try persist(prepared)
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

    private func persist(_ configuration: ModelMoorConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        try DurableAtomicWriter.write(data, to: fileURL, replacing: true)
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

private enum DurableAtomicWriter {
    static func write(_ data: Data, to destination: URL, replacing: Bool) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let fileDescriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fileDescriptor >= 0 else { throw posixError("create temporary configuration file") }
        var isOpen = true
        defer {
            if isOpen { close(fileDescriptor) }
            unlink(temporary.path)
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(fileDescriptor, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write configuration data")
                }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
        }
        guard fsync(fileDescriptor) == 0 else { throw posixError("sync configuration data") }
        guard close(fileDescriptor) == 0 else { throw posixError("close configuration file") }
        isOpen = false

        let result: Int32
        if replacing {
            result = rename(temporary.path, destination.path)
        } else {
            result = link(temporary.path, destination.path)
            if result == 0 { unlink(temporary.path) }
        }
        guard result == 0 else {
            if !replacing, errno == EEXIST { return }
            throw posixError("install configuration file")
        }

        let directoryDescriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw posixError("open configuration directory") }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw posixError("sync configuration directory") }
    }

    private static func posixError(_ operation: String) -> ConfigurationError {
        ConfigurationError.unreadable("Could not \(operation): \(String(cString: strerror(errno)))")
    }
}

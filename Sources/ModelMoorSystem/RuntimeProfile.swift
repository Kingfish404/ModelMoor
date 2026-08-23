import ModelMoorCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public enum ModelMoorBuildProfile: String, Sendable {
    case production
    case development
}

public struct ModelMoorRuntimeProfile: Equatable, Sendable {
    public static let buildProfileInfoKey = "ModelMoorBuildProfile"

    public let buildProfile: ModelMoorBuildProfile
    public let displayName: String
    public let bundleIdentifier: String
    public let configurationURL: URL
    public let legacyConfigurationURL: URL?
    public let applicationSupportDirectoryURL: URL
    public let tokenUsageURL: URL
    public let cliProxyDataDirectoryURL: URL
    public let preferencesURL: URL
    /// Service/label namespace used by the platform secret store backend
    /// (Keychain service on macOS; reserved for the Secret Service adapter).
    public let secretService: String
    public let legacySecretServices: [String]
    public let runtimeDirectoryURL: URL
    public let defaultGatewayPort: Int
    public let defaultCLIProxyPort: Int
    public let supportsLaunchAtLogin: Bool
    public let supportsSoftwareUpdates: Bool

    public var isDevelopment: Bool { buildProfile == .development }

    public var runtimeLockURL: URL {
        runtimeDirectoryURL.appendingPathComponent("runtime-owner.lock")
    }

    public var initialConfiguration: ModelMoorConfiguration {
        ModelMoorConfiguration(
            gateway: GatewayConfiguration(listenPort: defaultGatewayPort),
            cliProxy: CLIProxyConfiguration(listenPort: defaultCLIProxyPort),
            hasPreparedRecommendedEndpoints: false
        )
    }

    public static var current: Self {
        resolve()
    }

    public static func resolve(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: uid_t = getuid()
    ) -> Self {
        let declared = bundle.object(forInfoDictionaryKey: buildProfileInfoKey) as? String
        let profile = ModelMoorBuildProfile(rawValue: declared ?? "")
            ?? (bundle.bundleIdentifier?.hasSuffix(".dev") == true ? .development : .production)
        return make(
            profile,
            homeDirectory: homeDirectory,
            configurationHome: configurationHome(environment: environment, homeDirectory: homeDirectory),
            configurationOverrideURL: configurationOverrideURL(environment: environment),
            userID: userID
        )
    }

    public static func make(
        _ buildProfile: ModelMoorBuildProfile,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        configurationHome: URL? = nil,
        configurationOverrideURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userID: uid_t = getuid()
    ) -> Self {
        #if os(macOS)
        let dataHome = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let applicationDirectoryName = buildProfile == .development ? "ModelMoor Dev" : "ModelMoor"
        let preferences = homeDirectory.appendingPathComponent("Library/Preferences", isDirectory: true)
        #else
        let dataHome = PlatformPaths.dataHome(environment: environment, homeDirectory: homeDirectory)
        let applicationDirectoryName = buildProfile == .development ? "modelmoor-dev" : "modelmoor"
        let preferences = (configurationHome ?? PlatformPaths.configHome(
            environment: environment,
            homeDirectory: homeDirectory
        )).appendingPathComponent("modelmoor", isDirectory: true)
        #endif
        let modelMoorConfigurationDirectory = (configurationHome
            ?? homeDirectory.appendingPathComponent(".config", isDirectory: true))
            .appendingPathComponent("modelmoor", isDirectory: true)

        switch buildProfile {
        case .production:
            let dataDirectory = dataHome.appendingPathComponent(applicationDirectoryName, isDirectory: true)
            let bundleIdentifier = "com.modelmoor.app"
            return Self(
                buildProfile: .production,
                displayName: "ModelMoor",
                bundleIdentifier: bundleIdentifier,
                configurationURL: configurationOverrideURL
                    ?? modelMoorConfigurationDirectory.appendingPathComponent("config.json"),
                legacyConfigurationURL: configurationOverrideURL == nil && PlatformPaths.hasLegacyConfigurationLayout
                    ? dataDirectory.appendingPathComponent("config.json")
                    : nil,
                applicationSupportDirectoryURL: dataDirectory,
                tokenUsageURL: dataDirectory.appendingPathComponent("token-usage.jsonl"),
                cliProxyDataDirectoryURL: dataDirectory.appendingPathComponent("CLIProxyAPI", isDirectory: true),
                preferencesURL: preferences.appendingPathComponent("\(bundleIdentifier).plist"),
                secretService: SecretStoreSupport.productionService,
                legacySecretServices: [SecretStoreSupport.legacyProductionService],
                runtimeDirectoryURL: PlatformPaths.runtimeDirectory(
                    identifier: "modelmoor",
                    environment: environment,
                    userID: userID
                ),
                defaultGatewayPort: 17_777,
                defaultCLIProxyPort: 18_317,
                supportsLaunchAtLogin: PlatformPaths.supportsLaunchAtLogin,
                supportsSoftwareUpdates: true
            )
        case .development:
            let dataDirectory = dataHome.appendingPathComponent(applicationDirectoryName, isDirectory: true)
            let bundleIdentifier = "com.modelmoor.app.dev"
            return Self(
                buildProfile: .development,
                displayName: "ModelMoor Dev",
                bundleIdentifier: bundleIdentifier,
                configurationURL: configurationOverrideURL
                    ?? modelMoorConfigurationDirectory.appendingPathComponent("config.dev.json"),
                legacyConfigurationURL: configurationOverrideURL == nil && PlatformPaths.hasLegacyConfigurationLayout
                    ? dataDirectory.appendingPathComponent("config.json")
                    : nil,
                applicationSupportDirectoryURL: dataDirectory,
                tokenUsageURL: dataDirectory.appendingPathComponent("token-usage.jsonl"),
                cliProxyDataDirectoryURL: dataDirectory.appendingPathComponent("CLIProxyAPI", isDirectory: true),
                preferencesURL: preferences.appendingPathComponent("\(bundleIdentifier).plist"),
                secretService: "com.modelmoor.dev.api-token",
                legacySecretServices: [],
                runtimeDirectoryURL: PlatformPaths.runtimeDirectory(
                    identifier: "modelmoor-dev",
                    environment: environment,
                    userID: userID
                ),
                defaultGatewayPort: 27_777,
                defaultCLIProxyPort: 28_317,
                supportsLaunchAtLogin: false,
                supportsSoftwareUpdates: false
            )
        }
    }

    public static func configurationHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        PlatformPaths.configHome(environment: environment, homeDirectory: homeDirectory)
    }

    public static func configurationOverrideURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let rawValue = environment["MODELMOOR_CONFIG"], !rawValue.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString(string: rawValue).expandingTildeInPath)
    }
}

import Darwin
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
    public let keychainService: String
    public let legacyKeychainServices: [String]
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
        userID: uid_t = getuid()
    ) -> Self {
        let applicationSupport = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let preferences = homeDirectory.appendingPathComponent("Library/Preferences", isDirectory: true)
        let modelMoorConfigurationDirectory = (configurationHome
            ?? homeDirectory.appendingPathComponent(".config", isDirectory: true))
            .appendingPathComponent("modelmoor", isDirectory: true)

        switch buildProfile {
        case .production:
            let dataDirectory = applicationSupport.appendingPathComponent("ModelMoor", isDirectory: true)
            let bundleIdentifier = "com.modelmoor.app"
            return Self(
                buildProfile: .production,
                displayName: "ModelMoor",
                bundleIdentifier: bundleIdentifier,
                configurationURL: configurationOverrideURL
                    ?? modelMoorConfigurationDirectory.appendingPathComponent("config.json"),
                legacyConfigurationURL: configurationOverrideURL == nil
                    ? dataDirectory.appendingPathComponent("config.json")
                    : nil,
                applicationSupportDirectoryURL: dataDirectory,
                tokenUsageURL: dataDirectory.appendingPathComponent("token-usage.jsonl"),
                cliProxyDataDirectoryURL: dataDirectory.appendingPathComponent("CLIProxyAPI", isDirectory: true),
                preferencesURL: preferences.appendingPathComponent("\(bundleIdentifier).plist"),
                keychainService: KeychainTokenStore.productionService,
                legacyKeychainServices: [KeychainTokenStore.legacyProductionService],
                runtimeDirectoryURL: URL(fileURLWithPath: "/tmp/modelmoor-\(userID)", isDirectory: true),
                defaultGatewayPort: 17_777,
                defaultCLIProxyPort: 18_317,
                supportsLaunchAtLogin: true,
                supportsSoftwareUpdates: true
            )
        case .development:
            let dataDirectory = applicationSupport.appendingPathComponent("ModelMoor Dev", isDirectory: true)
            let bundleIdentifier = "com.modelmoor.app.dev"
            return Self(
                buildProfile: .development,
                displayName: "ModelMoor Dev",
                bundleIdentifier: bundleIdentifier,
                configurationURL: configurationOverrideURL
                    ?? modelMoorConfigurationDirectory.appendingPathComponent("config.dev.json"),
                legacyConfigurationURL: configurationOverrideURL == nil
                    ? dataDirectory.appendingPathComponent("config.json")
                    : nil,
                applicationSupportDirectoryURL: dataDirectory,
                tokenUsageURL: dataDirectory.appendingPathComponent("token-usage.jsonl"),
                cliProxyDataDirectoryURL: dataDirectory.appendingPathComponent("CLIProxyAPI", isDirectory: true),
                preferencesURL: preferences.appendingPathComponent("\(bundleIdentifier).plist"),
                keychainService: "com.modelmoor.dev.api-token",
                legacyKeychainServices: [],
                runtimeDirectoryURL: URL(fileURLWithPath: "/tmp/modelmoor-dev-\(userID)", isDirectory: true),
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
        if let rawValue = environment["XDG_CONFIG_HOME"], !rawValue.isEmpty {
            let expanded = NSString(string: rawValue).expandingTildeInPath
            if NSString(string: expanded).isAbsolutePath {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return homeDirectory.appendingPathComponent(".config", isDirectory: true)
    }

    public static func configurationOverrideURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let rawValue = environment["MODELMOOR_CONFIG"], !rawValue.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString(string: rawValue).expandingTildeInPath)
    }
}

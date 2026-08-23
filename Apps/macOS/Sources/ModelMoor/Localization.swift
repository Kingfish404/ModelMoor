import Foundation

enum AppLocalization {
    static let supportedLocalizations = ["en", "zh-Hans"]

    static func string(_ key: String) -> String {
        let mainValue = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        // The assembled .app flattens localizations into its standard Resources
        // directory. Bundle.module is available to SwiftPM builds and tests, but
        // its generated accessor must not be evaluated after that resource bundle
        // has deliberately been flattened into the application bundle.
        if Bundle.main.bundleURL.pathExtension == "app" { return mainValue }
        if mainValue != key { return mainValue }
        return Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }

    static func string(_ key: String, localeIdentifier: String) -> String {
        translations(localeIdentifier: localeIdentifier)[key] ?? key
    }

    static func translations(localeIdentifier: String) -> [String: String] {
        let localization = localeIdentifier.lowercased().hasPrefix("zh") ? "zh-hans" : "en"
        guard let path = Bundle.module.path(
            forResource: "Localizable",
            ofType: "strings",
            inDirectory: "\(localization).lproj"
        ),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: String] else {
            return [:]
        }
        return values
    }
}

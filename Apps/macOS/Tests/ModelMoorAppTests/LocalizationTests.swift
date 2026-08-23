@testable import ModelMoor
import XCTest

final class LocalizationTests: XCTestCase {
    func testSupportedLocalizationsResolveCriticalCommands() {
        XCTAssertEqual(AppLocalization.supportedLocalizations, ["en", "zh-Hans"])
        XCTAssertEqual(
            AppLocalization.string("Apply Changes", localeIdentifier: "en"),
            "Apply Changes"
        )
        XCTAssertEqual(
            AppLocalization.string("Apply Changes", localeIdentifier: "zh-Hans"),
            "应用更改"
        )
        XCTAssertEqual(
            AppLocalization.string("Copy Diagnostic Summary", localeIdentifier: "zh-CN"),
            "复制诊断摘要"
        )
        XCTAssertEqual(
            AppLocalization.string("Duplicate SSH Connection", localeIdentifier: "zh-Hans"),
            "复制 SSH 连接"
        )
    }

    func testEveryCriticalKeyHasARealSimplifiedChineseTranslation() {
        let keys = [
            "Overview",
            "SSH Connections",
            "API Endpoints",
            "Unified API",
            "Usage",
            "Settings",
            "Apply Changes Before Continuing?",
            "Apply Changes",
            "Discard Changes",
            "Cancel",
            "Copy Diagnostic Summary",
            "New API Endpoint…",
            "New SSH Connection…",
            "Duplicate API Endpoint",
            "Duplicate SSH Connection",
            "Refresh Status",
            "Navigate",
            "Search Sidebar",
            "Only direct HTTPS API endpoints can be duplicated."
        ]

        for key in keys {
            let localized = AppLocalization.string(key, localeIdentifier: "zh-Hans")
            XCTAssertNotEqual(localized, key, "Missing Simplified Chinese translation for \(key)")
            XCTAssertFalse(localized.isEmpty)
        }
    }

    func testEnglishAndSimplifiedChineseCatalogsStayInParity() {
        let english = AppLocalization.translations(localeIdentifier: "en")
        let chinese = AppLocalization.translations(localeIdentifier: "zh-Hans")
        let intentionallyUnchangedKeys: Set<String> = ["API", "DGX Spark API"]

        XCTAssertGreaterThanOrEqual(english.count, 300)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        for key in english.keys {
            XCTAssertFalse(english[key, default: ""].isEmpty, "Empty English value for \(key)")
            XCTAssertFalse(chinese[key, default: ""].isEmpty, "Empty Simplified Chinese value for \(key)")
            if !intentionallyUnchangedKeys.contains(key) {
                XCTAssertNotEqual(chinese[key], key, "Untranslated Simplified Chinese value for \(key)")
            }
        }
    }

    func testStringCatalogIsAuthoritativeForRuntimeSidecars() throws {
        let english = AppLocalization.translations(localeIdentifier: "en")
        let chinese = AppLocalization.translations(localeIdentifier: "zh-Hans")
        let catalog = try simplifiedChineseCatalog()

        XCTAssertEqual(Set(catalog.keys), Set(english.keys))
        XCTAssertEqual(Set(catalog.keys), Set(chinese.keys))
        for key in catalog.keys {
            XCTAssertFalse(english[key, default: ""].isEmpty, "Missing compiled English value for \(key)")
            XCTAssertEqual(chinese[key], catalog[key], "Stale SwiftPM sidecar for \(key)")
        }
    }

    private func simplifiedChineseCatalog() throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "Localizable",
            withExtension: "xcstrings"
        ))
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["sourceLanguage"] as? String, "en")
        XCTAssertEqual(root["version"] as? String, "1.0")
        let entries = try XCTUnwrap(root["strings"] as? [String: Any])

        var result: [String: String] = [:]
        for (key, rawEntry) in entries {
            let entry = try XCTUnwrap(rawEntry as? [String: Any])
            XCTAssertEqual(entry["extractionState"] as? String, "manual")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let chinese = try XCTUnwrap(localizations["zh-Hans"] as? [String: Any])
            let unit = try XCTUnwrap(chinese["stringUnit"] as? [String: Any])
            XCTAssertEqual(unit["state"] as? String, "translated")
            result[key] = try XCTUnwrap(unit["value"] as? String)
        }
        return result
    }
}

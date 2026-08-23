import Darwin
import Foundation

struct Catalog: Decodable {
    let strings: [String: CatalogEntry]
}

struct CatalogEntry: Decodable {}

struct StringsData: Decodable {
    let tables: [String: [ExtractedString]]
}

struct ExtractedString: Decodable {
    let key: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: check-localization-coverage.swift <catalog> <stringsdata-directory> <source-directory>")
}

let fileManager = FileManager.default
let catalogURL = URL(fileURLWithPath: CommandLine.arguments[1])
let stringsDataDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let sourceDirectory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
let decoder = JSONDecoder()

let catalog: Catalog
do {
    catalog = try decoder.decode(Catalog.self, from: Data(contentsOf: catalogURL))
} catch {
    fail("could not decode \(catalogURL.path): \(error)")
}

let sourceURLs: [URL]
do {
    sourceURLs = try fileManager.contentsOfDirectory(
        at: sourceDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension == "swift" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
} catch {
    fail("could not enumerate \(sourceDirectory.path): \(error)")
}

var sourceKeys = Set<String>()
for sourceURL in sourceURLs {
    let stringsDataURL = stringsDataDirectory
        .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent)
        .appendingPathExtension("stringsdata")
    guard fileManager.fileExists(atPath: stringsDataURL.path) else {
        fail("missing compiler extraction for \(sourceURL.lastPathComponent)")
    }

    do {
        let extraction = try decoder.decode(
            StringsData.self,
            from: Data(contentsOf: stringsDataURL)
        )
        for entry in extraction.tables["Localizable", default: []] where !entry.key.isEmpty {
            sourceKeys.insert(entry.key)
        }
    } catch {
        fail("could not decode \(stringsDataURL.path): \(error)")
    }
}

let missing = sourceKeys.subtracting(catalog.strings.keys).sorted()
guard missing.isEmpty else {
    let list = missing.map { "  - \($0)" }.joined(separator: "\n")
    fail("String Catalog is missing \(missing.count) compiler-extracted key(s):\n\(list)")
}

print("String Catalog covers all \(sourceKeys.count) compiler-extracted GUI keys")

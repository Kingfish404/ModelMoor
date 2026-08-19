import Foundation

public struct AppVersion: Comparable, Sendable {
    private enum PrereleaseIdentifier: Equatable, Sendable {
        case number(Int)
        case text(String)
    }

    private let components: [Int]
    private let prerelease: [PrereleaseIdentifier]?

    public init?(_ value: String) {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        value = String(value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0])

        let versionParts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numericParts = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !numericParts.isEmpty,
              numericParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              var components = Optional(numericParts.compactMap { Int($0) }),
              components.count == numericParts.count else {
            return nil
        }
        while components.count > 1, components.last == 0 {
            components.removeLast()
        }
        self.components = components

        if versionParts.count == 1 {
            prerelease = nil
        } else {
            let identifiers = versionParts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty,
                  identifiers.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else {
                return nil
            }
            prerelease = identifiers.map { identifier in
                if identifier.allSatisfy(\.isNumber), let number = Int(identifier) {
                    return .number(number)
                }
                return .text(String(identifier))
            }
        }
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<componentCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case let (.some(left), .some(right)):
            for index in 0..<min(left.count, right.count) {
                if left[index] == right[index] { continue }
                switch (left[index], right[index]) {
                case let (.number(a), .number(b)): return a < b
                case (.number, .text): return true
                case (.text, .number): return false
                case let (.text(a), .text(b)): return a < b
                }
            }
            return left.count < right.count
        }
    }
}

public struct AppRelease: Equatable, Sendable {
    public let tagName: String
    public let pageURL: URL
    public let downloadURL: URL?
    public let publishedAt: Date?

    public init(tagName: String, pageURL: URL, downloadURL: URL?, publishedAt: Date?) {
        self.tagName = tagName
        self.pageURL = pageURL
        self.downloadURL = downloadURL
        self.publishedAt = publishedAt
    }

    public var version: AppVersion? { AppVersion(tagName) }
}

public protocol AppReleaseChecking: Sendable {
    func latestRelease() async throws -> AppRelease
}

public enum AppReleaseCheckError: LocalizedError, Equatable, Sendable {
    case noPublishedRelease
    case invalidResponse
    case invalidRelease
    case serverStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .noPublishedRelease:
            "No published GitHub release was found."
        case .invalidResponse:
            "GitHub returned an invalid response."
        case .invalidRelease:
            "The latest GitHub release does not have a valid version tag."
        case let .serverStatus(status):
            "GitHub returned status code \(status)."
        }
    }
}

public struct GitHubReleaseChecker: AppReleaseChecking, Sendable {
    private struct Response: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let publishedAt: Date?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
        }
    }

    private let endpoint: URL
    private let userAgent: String

    public init(owner: String, repository: String, userAgent: String) {
        endpoint = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
        self.userAgent = userAgent
    }

    public func latestRelease() async throws -> AppRelease {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AppReleaseCheckError.invalidResponse
        }
        if response.statusCode == 404 {
            throw AppReleaseCheckError.noPublishedRelease
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AppReleaseCheckError.serverStatus(response.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let release = try? decoder.decode(Response.self, from: data),
              AppVersion(release.tagName) != nil else {
            throw AppReleaseCheckError.invalidRelease
        }

        let downloadURL = preferredDownload(in: release.assets)
        return AppRelease(
            tagName: release.tagName,
            pageURL: release.htmlURL,
            downloadURL: downloadURL,
            publishedAt: release.publishedAt
        )
    }

    private func preferredDownload(in assets: [Response.Asset]) -> URL? {
        let supportedExtensions = [".dmg", ".zip"]
        return assets.first { asset in
            let name = asset.name.lowercased()
            return name.contains("modelmoor") && supportedExtensions.contains(where: name.hasSuffix)
        }?.browserDownloadURL
    }
}

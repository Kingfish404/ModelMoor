import AppKit
import Foundation
import ModelMoorCore
import ModelMoorSystem

@MainActor
final class UpdateController: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(AppRelease)
        case failed(String)
    }

    enum CheckOutcome: Sendable {
        case upToDate
        case updateAvailable(AppRelease)
        case failed(String)
        case alreadyChecking
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var automaticChecksEnabled: Bool
    @Published private(set) var lastCheckedAt: Date?

    let currentVersion: String
    let updatesAvailable: Bool

    private static let automaticChecksKey = "softwareUpdates.automaticChecksEnabled"
    private static let lastCheckedAtKey = "softwareUpdates.lastCheckedAt"
    private static let automaticCheckInterval: Duration = .seconds(3 * 60 * 60)

    private let currentAppVersion: AppVersion
    private let checker: any AppReleaseChecking
    private let defaults: UserDefaults
    private var automaticCheckTask: Task<Void, Never>?

    init(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        updatesAvailable: Bool = true,
        checker: (any AppReleaseChecking)? = nil
    ) {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        currentVersion = version
        currentAppVersion = AppVersion(version) ?? AppVersion("0.0.0")!
        self.updatesAvailable = updatesAvailable
        self.defaults = defaults
        if !updatesAvailable {
            automaticChecksEnabled = false
        } else if defaults.object(forKey: Self.automaticChecksKey) == nil {
            automaticChecksEnabled = true
        } else {
            automaticChecksEnabled = defaults.bool(forKey: Self.automaticChecksKey)
        }
        lastCheckedAt = defaults.object(forKey: Self.lastCheckedAtKey) as? Date
        self.checker = checker ?? GitHubReleaseChecker(
            owner: "Kingfish404",
            repository: "ModelMoor",
            userAgent: "ModelMoor/\(version)"
        )
    }

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    var availableRelease: AppRelease? {
        if case let .updateAvailable(release) = state { return release }
        return nil
    }

    var statusText: String {
        if !updatesAvailable { return AppLocalization.string("Update checks are disabled for development builds.") }
        return switch state {
        case .idle:
            AppLocalization.string(lastCheckedAt == nil
                ? "Updates have not been checked yet."
                : "No new update was found last time.")
        case .checking:
            AppLocalization.string("Checking GitHub for updates…")
        case .upToDate:
            AppLocalization.string("ModelMoor is up to date.")
        case let .updateAvailable(release):
            AppLocalization.format("ModelMoor %@ is available.", release.tagName)
        case let .failed(message):
            message
        }
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        guard updatesAvailable else {
            automaticChecksEnabled = false
            return
        }
        automaticChecksEnabled = enabled
        defaults.set(enabled, forKey: Self.automaticChecksKey)
        if enabled { start() } else { stop() }
    }

    func start() {
        guard updatesAvailable, automaticChecksEnabled, automaticCheckTask == nil else { return }
        automaticCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.checkNow()
                do {
                    try await Task.sleep(for: Self.automaticCheckInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        automaticCheckTask?.cancel()
        automaticCheckTask = nil
    }

    func checkNow() async -> CheckOutcome {
        guard updatesAvailable else {
            let message = AppLocalization.string("Update checks are disabled for development builds.")
            state = .failed(message)
            return .failed(message)
        }
        guard !isChecking else { return .alreadyChecking }
        state = .checking

        do {
            let release = try await checker.latestRelease()
            recordCheckDate()
            guard let releaseVersion = release.version else {
                throw AppReleaseCheckError.invalidRelease
            }
            if releaseVersion > currentAppVersion {
                state = .updateAvailable(release)
                return .updateAvailable(release)
            }
            state = .upToDate
            return .upToDate
        } catch {
            recordCheckDate()
            let message = error.localizedDescription
            state = .failed(message)
            return .failed(message)
        }
    }

    func openReleasePage(_ release: AppRelease) {
        NSWorkspace.shared.open(release.pageURL)
    }

    func download(_ release: AppRelease) {
        NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
    }

    private func recordCheckDate() {
        let now = Date()
        lastCheckedAt = now
        defaults.set(now, forKey: Self.lastCheckedAtKey)
    }
}

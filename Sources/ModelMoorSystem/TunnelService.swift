import ModelMoorCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public actor TunnelService {
    public typealias StatusHandler = @Sendable (TunnelStatus) -> Void

    private let commandBuilder: SSHCommandBuilder
    private let localPortPreflight: @Sendable (TunnelConfiguration) throws -> Void
    private let statusHandler: StatusHandler
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var runningConfigurations: [UUID: TunnelConfiguration] = [:]
    private var desiredConfigurations: [UUID: TunnelConfiguration] = [:]
    private var runtimePauseReason: String?

    public init(
        commandBuilder: SSHCommandBuilder = SSHCommandBuilder(),
        localPortPreflight: @escaping @Sendable (TunnelConfiguration) throws -> Void = TunnelService.systemLocalPortPreflight,
        statusHandler: @escaping StatusHandler
    ) {
        self.commandBuilder = commandBuilder
        self.localPortPreflight = localPortPreflight
        self.statusHandler = statusHandler
    }

    public func start(_ tunnel: TunnelConfiguration) async {
        desiredConfigurations[tunnel.id] = tunnel
        guard runtimePauseReason == nil else {
            reportWaitingForRuntime(tunnel.id)
            return
        }
        await startRunning(tunnel)
    }

    private func startRunning(_ tunnel: TunnelConfiguration) async {
        await stopRunning(tunnel.id)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runLoop(tunnel)
        }
        tasks[tunnel.id] = task
        runningConfigurations[tunnel.id] = tunnel
    }

    public func startAll(_ tunnels: [TunnelConfiguration]) async {
        await reconcile(tunnels)
    }

    public func reconcile(_ tunnels: [TunnelConfiguration]) async {
        let desired = Dictionary(uniqueKeysWithValues: tunnels.map { ($0.id, $0) })
        desiredConfigurations = desired
        let idsToStop = runningConfigurations.compactMap { id, current in
            desired[id] == current ? nil : id
        }
        for id in idsToStop {
            await stopRunning(id)
        }
        guard runtimePauseReason == nil else {
            for id in desired.keys { reportWaitingForRuntime(id) }
            return
        }
        for tunnel in tunnels where runningConfigurations[tunnel.id] == nil {
            await startRunning(tunnel)
        }
    }

    public func stop(_ id: UUID) async {
        desiredConfigurations[id] = nil
        await stopRunning(id)
    }

    private func stopRunning(_ id: UUID) async {
        let task = tasks[id]
        if task != nil {
            statusHandler(TunnelStatus(
                tunnelID: id,
                phase: .disconnecting,
                message: "Closing SSH tunnel"
            ))
        }
        task?.cancel()
        tasks[id] = nil
        runningConfigurations[id] = nil
        await task?.value
    }

    public func stopAll() async {
        desiredConfigurations.removeAll()
        await stopAllRunning()
    }

    private func stopAllRunning() async {
        let running = Array(tasks.values)
        for task in running {
            task.cancel()
        }
        tasks.removeAll()
        runningConfigurations.removeAll()
        for task in running {
            await task.value
        }
    }

    public func setRuntimeAvailable(_ available: Bool, reason: String = "Network unavailable") async {
        if available {
            guard runtimePauseReason != nil else { return }
            runtimePauseReason = nil
            let desired = Array(desiredConfigurations.values)
            for tunnel in desired where runningConfigurations[tunnel.id] == nil {
                await startRunning(tunnel)
            }
        } else {
            runtimePauseReason = reason
            await stopAllRunning()
            for id in desiredConfigurations.keys { reportWaitingForRuntime(id) }
        }
    }

    private func reportWaitingForRuntime(_ tunnelID: UUID) {
        statusHandler(TunnelStatus(
            tunnelID: tunnelID,
            phase: .waitingForNetwork,
            message: runtimePauseReason ?? "Waiting for network"
        ))
    }

    private func runLoop(_ tunnel: TunnelConfiguration) async {
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            statusHandler(TunnelStatus(
                tunnelID: tunnel.id,
                phase: .connecting,
                message: attempt == 1 ? "Opening SSH tunnel" : "Reconnecting",
                retryAttempt: attempt - 1
            ))

            do {
                try await runAttempt(tunnel)
            } catch is CancellationError {
                break
            } catch let failure as SSHSessionFailure {
                if failure.resetBackoff { attempt = 0 }
                guard tunnel.autoReconnect else {
                    reportFailure(tunnelID: tunnel.id, detail: failure.detail, category: failure.category)
                    return
                }
                do {
                    try await waitToRetry(
                        tunnel: tunnel,
                        attempt: max(attempt, 1),
                        detail: failure.detail,
                        category: failure.category
                    )
                } catch {
                    break
                }
            } catch {
                guard !Task.isCancelled else { break }
                guard tunnel.autoReconnect else {
                    reportFailure(tunnelID: tunnel.id, detail: error.localizedDescription)
                    return
                }
                do {
                    try await waitToRetry(
                        tunnel: tunnel,
                        attempt: max(attempt, 1),
                        detail: error.localizedDescription,
                        category: .unknown
                    )
                } catch {
                    break
                }
            }
        }
        statusHandler(TunnelStatus(tunnelID: tunnel.id, phase: .stopped, message: "Stopped"))
    }

    private func runAttempt(_ tunnel: TunnelConfiguration) async throws {
        try prepareControlDirectory()
        await stopStaleMaster(for: tunnel)
        do {
            try localPortPreflight(tunnel)
        } catch let failure as TunnelPreflightFailure {
            throw SSHSessionFailure(
                detail: failure.detail,
                resetBackoff: false,
                category: failure.category
            )
        }

        let process = try SSHProcess.launchSupervised(commandBuilder.command(for: tunnel))
        var connected = false
        var connectedAt: Date?
        do {
            try await waitUntilMasterIsReady(process, tunnel: tunnel)

            let forward = try await SSHProcess.run(
                commandBuilder.controlCommand(.forward, for: tunnel)
            )
            guard forward.terminationStatus == 0 else {
                let detail = forward.errorText.isEmpty
                    ? "SSH forwarding setup exited with code \(forward.terminationStatus)"
                    : SSHFailureDetail.message(for: tunnel, errorText: forward.errorText)
                let category = SSHFailureDetail.category(for: tunnel, errorText: forward.errorText)
                throw SSHSessionFailure(detail: detail, resetBackoff: false, category: category)
            }

            connected = true
            connectedAt = Date()
            statusHandler(TunnelStatus(
                tunnelID: tunnel.id,
                phase: .connected,
                message: connectedMessage(for: tunnel)
            ))

            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(1))
            }
            try Task.checkCancellation()

            let exitCode = process.terminationStatus.map(String.init) ?? "unknown"
            let detail = process.errorText.isEmpty
                ? "SSH master exited with code \(exitCode)"
                : SSHFailureDetail.message(for: tunnel, errorText: process.errorText)
            let healthyForAtLeastOneMinute = connectedAt.map { Date().timeIntervalSince($0) >= 60 } ?? false
            throw SSHSessionFailure(
                detail: detail,
                resetBackoff: healthyForAtLeastOneMinute,
                category: SSHFailureDetail.category(for: tunnel, errorText: process.errorText, default: .processExited)
            )
        } catch {
            await closeMaster(for: tunnel, process: process)
            if error is CancellationError {
                throw error
            }
            if let failure = error as? SSHSessionFailure {
                throw failure
            }
            if connected {
                throw SSHSessionFailure(detail: error.localizedDescription, resetBackoff: false, category: .unknown)
            }
            throw error
        }
    }

    private func prepareControlDirectory() throws {
        let fileManager = FileManager.default
        let path = commandBuilder.controlDirectoryURL.path
        if fileManager.fileExists(atPath: path) {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            let type = attributes[.type] as? FileAttributeType
            let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            guard type == .typeDirectory, ownerID == getuid() else {
                throw SSHControlDirectoryError(path: path)
            }
        } else {
            try fileManager.createDirectory(
                at: commandBuilder.controlDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: path
        )
    }

    private func stopStaleMaster(for tunnel: TunnelConfiguration) async {
        _ = try? await SSHProcess.run(commandBuilder.controlCommand(.exit, for: tunnel))
        removeControlSocket(for: tunnel)
    }

    private func waitUntilMasterIsReady(
        _ process: SSHProcess,
        tunnel: TunnelConfiguration
    ) async throws {
        let clock = ContinuousClock()
        let timeout = Duration.seconds(max(tunnel.connectTimeoutSeconds + 5, 10))
        let deadline = clock.now.advanced(by: timeout)
        var lastCheckError = ""

        while process.isRunning {
            try Task.checkCancellation()
            let check = try await SSHProcess.run(
                commandBuilder.controlCommand(.check, for: tunnel)
            )
            if check.terminationStatus == 0 { return }
            lastCheckError = check.errorText
            guard clock.now < deadline else {
                let detail = lastCheckError.isEmpty
                    ? "Timed out waiting for the SSH master control socket"
                    : lastCheckError
                throw SSHSessionFailure(
                    detail: detail,
                    resetBackoff: false,
                    category: SSHFailureDetail.category(for: tunnel, errorText: lastCheckError)
                )
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let exitCode = process.terminationStatus.map(String.init) ?? "unknown"
        let detail = process.errorText.isEmpty
            ? "SSH master exited with code \(exitCode) before becoming ready"
            : SSHFailureDetail.message(for: tunnel, errorText: process.errorText)
        throw SSHSessionFailure(
            detail: detail,
            resetBackoff: false,
            category: SSHFailureDetail.category(for: tunnel, errorText: process.errorText, default: .processExited)
        )
    }

    private func closeMaster(for tunnel: TunnelConfiguration, process: SSHProcess) async {
        _ = try? await SSHProcess.run(commandBuilder.controlCommand(.cancel, for: tunnel))
        _ = try? await SSHProcess.run(commandBuilder.controlCommand(.exit, for: tunnel))
        process.terminate()
        removeControlSocket(for: tunnel)
    }

    private func removeControlSocket(for tunnel: TunnelConfiguration) {
        let path = commandBuilder.controlPath(for: tunnel)
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func connectedMessage(for tunnel: TunnelConfiguration) -> String {
        let count = tunnel.enabledMappings.count
        return count == 1 ? "1 port forward active" : "\(count) port forwards active"
    }

    private func waitToRetry(
        tunnel: TunnelConfiguration,
        attempt: Int,
        detail: String,
        category: TunnelFailureCategory
    ) async throws {
        let policy = ReconnectPolicy(
            initialDelay: .seconds(tunnel.reconnectInitialDelaySeconds),
            maximumDelay: .seconds(tunnel.reconnectMaximumDelaySeconds)
        )
        let delay = category.requiresUserAction
            ? Duration.seconds(300)
            : policy.jitteredDelay(afterAttempt: attempt)
        let seconds = delay.components.seconds
        statusHandler(TunnelStatus(
            tunnelID: tunnel.id,
            phase: .waitingToRetry,
            message: "\(detail) Retrying in \(seconds)s",
            retryAttempt: attempt,
            failureCategory: category
        ))
        try await Task.sleep(for: delay)
    }

    private func reportFailure(
        tunnelID: UUID,
        detail: String,
        category: TunnelFailureCategory = .unknown
    ) {
        statusHandler(TunnelStatus(
            tunnelID: tunnelID,
            phase: .failed,
            message: detail,
            failureCategory: category
        ))
    }

    public static func systemLocalPortPreflight(for tunnel: TunnelConfiguration) throws {
        for mapping in tunnel.enabledMappings where mapping.direction.listensLocally {
            #if canImport(Darwin)
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            #else
            let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            #endif
            guard descriptor >= 0 else {
                throw TunnelPreflightFailure(
                    detail: "Could not check local port \(mapping.listenPort): \(String(cString: strerror(errno)))",
                    category: .unknown
                )
            }
            defer { close(descriptor) }
            var address = sockaddr_in()
            #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(mapping.listenPort).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else {
                let detail = errno == EADDRINUSE
                    ? "Local port 127.0.0.1:\(mapping.listenPort) is already in use. Choose another local listen port or stop the existing listener."
                    : "Could not bind local port 127.0.0.1:\(mapping.listenPort): \(String(cString: strerror(errno)))"
                throw TunnelPreflightFailure(
                    detail: detail,
                    category: errno == EADDRINUSE ? .localPortInUse : .unknown
                )
            }
        }
    }
}

public struct TunnelPreflightFailure: LocalizedError, Equatable, Sendable {
    public let detail: String
    public let category: TunnelFailureCategory

    public init(detail: String, category: TunnelFailureCategory) {
        self.detail = detail
        self.category = category
    }

    public var errorDescription: String? { detail }
}

private struct SSHSessionFailure: LocalizedError {
    let detail: String
    let resetBackoff: Bool
    let category: TunnelFailureCategory

    var errorDescription: String? { detail }
}

private struct SSHControlDirectoryError: LocalizedError {
    let path: String

    var errorDescription: String? {
        "SSH control directory is not a user-owned directory: \(path)"
    }
}

enum SSHFailureDetail {
    static func message(for tunnel: TunnelConfiguration, errorText: String) -> String {
        for mapping in tunnel.enabledMappings where !mapping.direction.listensLocally {
            let failure = "remote port forwarding failed for listen port \(mapping.listenPort)"
            guard errorText.localizedCaseInsensitiveContains(failure) else { continue }
            return "Remote port \(mapping.listenHost):\(mapping.listenPort) is already in use on \(tunnel.sshHost). Choose another remote listen port or stop the existing listener."
        }
        return errorText
    }

    static func category(
        for tunnel: TunnelConfiguration,
        errorText: String,
        default defaultCategory: TunnelFailureCategory = .unknown
    ) -> TunnelFailureCategory {
        let lowercased = errorText.lowercased()
        if tunnel.enabledMappings.contains(where: { mapping in
            !mapping.direction.listensLocally
                && lowercased.contains("remote port forwarding failed for listen port \(mapping.listenPort)")
        }) { return .remoteForwardConflict }
        if lowercased.contains("permission denied")
            || lowercased.contains("no supported authentication methods") { return .sshAuthentication }
        if lowercased.contains("host key verification failed")
            || lowercased.contains("remote host identification has changed")
            || lowercased.contains("offending") && lowercased.contains("key") { return .hostKey }
        if lowercased.contains("could not resolve hostname")
            || lowercased.contains("nodename nor servname provided") { return .dns }
        if lowercased.contains("bad configuration option")
            || lowercased.contains("terminating, 1 bad configuration options") { return .sshConfiguration }
        return defaultCategory
    }
}

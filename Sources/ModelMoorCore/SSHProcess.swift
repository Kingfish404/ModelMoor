import Foundation

struct SSHCommandResult: Equatable, Sendable {
    let terminationStatus: Int32
    let errorText: String
}

final class SSHProcess: @unchecked Sendable {
    private static let supervisionScript = #"""
    owner_pid="$1"
    shift
    child_pid=""

    terminate_child() {
      trap - HUP INT TERM
      if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
        kill -TERM "$child_pid" 2>/dev/null
      fi
      if [ -n "$child_pid" ]; then
        wait "$child_pid" 2>/dev/null
      fi
      exit 0
    }

    trap terminate_child HUP INT TERM
    "$@" &
    child_pid=$!

    while kill -0 "$child_pid" 2>/dev/null; do
      if ! kill -0 "$owner_pid" 2>/dev/null; then
        terminate_child
      fi
      sleep 1
    done

    wait "$child_pid"
    status=$?
    child_pid=""
    exit "$status"
    """#

    private let process: Process
    private let errorPipe: Pipe
    private let lock = NSLock()
    private var errorData = Data()
    private var exitStatus: Int32?
    private var exitContinuations: [CheckedContinuation<Int32, Never>] = []

    private init(process: Process, errorPipe: Pipe) {
        self.process = process
        self.errorPipe = errorPipe
    }

    static func launch(_ command: SSHCommand) throws -> SSHProcess {
        let process = Process()
        let errorPipe = Pipe()
        let instance = SSHProcess(process: process, errorPipe: errorPipe)

        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        process.terminationHandler = { [weak instance] process in
            instance?.processDidExit(process.terminationStatus)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak instance] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            instance?.appendErrorData(data)
        }
        try process.run()
        return instance
    }

    static func launchSupervised(
        _ command: SSHCommand,
        ownerPID: Int32 = getpid()
    ) throws -> SSHProcess {
        let supervisedCommand = SSHCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                supervisionScript,
                "modelmoor-ssh-watchdog",
                String(ownerPID),
                command.executableURL.path
            ] + command.arguments
        )
        return try launch(supervisedCommand)
    }

    static func run(_ command: SSHCommand) async throws -> SSHCommandResult {
        let process = try launch(command)
        let status = await process.waitForExit()
        process.finishReadingError()
        return SSHCommandResult(terminationStatus: status, errorText: process.errorText)
    }

    var isRunning: Bool {
        process.isRunning
    }

    var terminationStatus: Int32? {
        process.isRunning ? nil : process.terminationStatus
    }

    var errorText: String {
        lock.withLock {
            String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let completed = lock.withLock { () -> Int32? in
                if let exitStatus { return exitStatus }
                exitContinuations.append(continuation)
                return nil
            }
            if let completed { continuation.resume(returning: completed) }
        }
    }

    func terminate() {
        errorPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    private func finishReadingError() {
        errorPipe.fileHandleForReading.readabilityHandler = nil
        let remaining = errorPipe.fileHandleForReading.availableData
        if !remaining.isEmpty {
            appendErrorData(remaining)
        }
    }

    private func appendErrorData(_ data: Data) {
        lock.withLock {
            errorData.append(data)
            if errorData.count > 16_384 {
                errorData = errorData.suffix(16_384)
            }
        }
    }

    private func processDidExit(_ status: Int32) {
        let continuations = lock.withLock { () -> [CheckedContinuation<Int32, Never>] in
            exitStatus = status
            let current = exitContinuations
            exitContinuations.removeAll(keepingCapacity: false)
            return current
        }
        continuations.forEach { $0.resume(returning: status) }
    }

    deinit {
        terminate()
    }
}

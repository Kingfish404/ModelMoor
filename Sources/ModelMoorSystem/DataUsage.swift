import Foundation

public struct DataUsageSeriesPoint: Identifiable, Sendable {
    public var timestamp: Date
    public var bytes: Int64
    public var id: Date { timestamp }
}

public struct DataUsageBreakdown: Identifiable, Sendable {
    public var mappingID: UUID
    public var tunnelID: UUID
    public var bytes: Int64
    public var id: String { "\(tunnelID):\(mappingID)" }
}

public struct DataUsageDirectionReport: Sendable {
    public var totalBytes: Int64
    public var series: [DataUsageSeriesPoint]
    public var breakdowns: [DataUsageBreakdown]

    public func point(nearestTo date: Date) -> DataUsageSeriesPoint? {
        series.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
    }
}

/// Sent and received are relative to the machine running ModelMoor.
public struct DataUsageReport: Sendable {
    public var sent: DataUsageDirectionReport
    public var received: DataUsageDirectionReport
}

/// One journal record commits both directions together. Five-second sampling
/// keeps disk I/O off the packet path; records contain no hosts or payloads.
public actor DataUsageStore {
    private struct Record: Codable {
        var timestamp: Date
        var mappingID: UUID
        var tunnelID: UUID
        var sent: Int64
        var received: Int64
    }
    private struct Key: Hashable {
        var mappingID: UUID
        var tunnelID: UUID
    }
    public let fileURL: URL
    private var records: [Record]?
    private var pending: [Record] = []
    private var nextCompaction = Date.distantPast

    public init(directoryURL: URL) {
        fileURL = directoryURL.appendingPathComponent("data-usage.jsonl")
    }

    public func record(mappingID: UUID, tunnelID: UUID, sent: Int64, received: Int64, at date: Date = Date()) throws {
        guard sent >= 0, received >= 0 else { throw DataUsageError.invalidCounts }
        if sent > 0 || received > 0 {
            pending.append(Record(timestamp: date, mappingID: mappingID, tunnelID: tunnelID, sent: sent, received: received))
        }
        guard !pending.isEmpty else { return }
        try load(now: date)
        try flush()
    }

    private func flush() throws {
        guard !pending.isEmpty else { return }
        var data = Data()
        let encoder = JSONEncoder()
        for record in pending {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try handle.truncate(atOffset: offset)
            throw error
        }
        records?.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
    }

    public func report(from start: Date, to end: Date, bucketInterval: TimeInterval, mappingID: UUID? = nil) throws -> DataUsageReport {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
              start <= end, bucketInterval.isFinite, bucketInterval >= 1,
              end.timeIntervalSince(start) / bucketInterval <= 4094 else { throw DataUsageError.invalidRange }
        try Task.checkCancellation()
        try load(now: Date())
        try flush()
        let first = floor(start.timeIntervalSince1970 / bucketInterval) * bucketInterval
        let count = Int(floor((end.timeIntervalSince1970 - first) / bucketInterval)) + 1
        let empty = (0..<count).map { DataUsageSeriesPoint(timestamp: Date(timeIntervalSince1970: first + Double($0) * bucketInterval), bytes: 0) }
        var sent = DataUsageDirectionReport(totalBytes: 0, series: empty, breakdowns: [])
        var received = sent
        var groups: [Key: (sent: Int64, received: Int64)] = [:]
        for record in records ?? [] where record.timestamp >= start && record.timestamp <= end && (mappingID == nil || mappingID == record.mappingID) {
            try Task.checkCancellation()
            let index = Int(floor((record.timestamp.timeIntervalSince1970 - first) / bucketInterval))
            sent.totalBytes = addingBytes(sent.totalBytes, record.sent)
            received.totalBytes = addingBytes(received.totalBytes, record.received)
            sent.series[index].bytes = addingBytes(sent.series[index].bytes, record.sent)
            received.series[index].bytes = addingBytes(received.series[index].bytes, record.received)
            let key = Key(mappingID: record.mappingID, tunnelID: record.tunnelID)
            let old = groups[key] ?? (0, 0)
            groups[key] = (addingBytes(old.sent, record.sent), addingBytes(old.received, record.received))
        }
        for (key, value) in groups {
            sent.breakdowns.append(DataUsageBreakdown(mappingID: key.mappingID, tunnelID: key.tunnelID, bytes: value.sent))
            received.breakdowns.append(DataUsageBreakdown(mappingID: key.mappingID, tunnelID: key.tunnelID, bytes: value.received))
        }
        sent.breakdowns.sort { $0.id < $1.id }
        received.breakdowns.sort { $0.id < $1.id }
        return DataUsageReport(sent: sent, received: received)
    }

    private func load(now: Date) throws {
        let directory = fileURL.deletingLastPathComponent()
        if records == nil {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                // Only a final unterminated record can be a crash-torn write.
                let complete = data.lastIndex(of: 0x0A).map { data.prefix(through: $0) } ?? Data()
                let decoded = try complete.split(separator: 0x0A).map { try JSONDecoder().decode(Record.self, from: Data($0)) }
                guard decoded.allSatisfy({ $0.sent >= 0 && $0.received >= 0 && $0.timestamp.timeIntervalSince1970.isFinite }) else {
                    throw DataUsageError.invalidCounts
                }
                records = decoded
            } else {
                records = []
            }
        }
        if now >= nextCompaction {
            let retained = (records ?? []).filter { $0.timestamp >= now.addingTimeInterval(-31 * 86400) }
            var data = Data()
            let encoder = JSONEncoder()
            for record in retained {
                data.append(try encoder.encode(record))
                data.append(0x0A)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try DurableAtomicWriter.writeAtomically(data, to: fileURL, replacing: true)
            records = retained
            nextCompaction = now.addingTimeInterval(3600)
        }
    }
}

public enum DataUsageError: LocalizedError {
    case invalidCounts
    case invalidRange
    public var errorDescription: String? {
        switch self {
        case .invalidCounts: "Data usage contains invalid byte counts."
        case .invalidRange: "The requested data usage range is invalid."
        }
    }
}

private func addingBytes(_ a: Int64, _ b: Int64) -> Int64 {
    let (sum, overflow) = a.addingReportingOverflow(b)
    return overflow ? .max : sum
}

/// Synchronous counters avoid creating a task or writing a file per packet.
final class ForwardTrafficCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: Int64 = 0
    private var received: Int64 = 0

    func add(_ count: Int, sent: Bool) {
        lock.withLock {
            if sent { self.sent = addingBytes(self.sent, Int64(count)) }
            else { received = addingBytes(received, Int64(count)) }
        }
    }

    func drain() -> (sent: Int64, received: Int64) {
        lock.withLock {
            defer { sent = 0; received = 0 }
            return (sent, received)
        }
    }
}

import ModelMoorCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public struct TokenUsageSnapshot: Equatable, Sendable {
    public var lastMinute: Int64
    public var lastHour: Int64
    public var lastDay: Int64
    public var last30Days: Int64

    public init(
        lastMinute: Int64 = 0,
        lastHour: Int64 = 0,
        lastDay: Int64 = 0,
        last30Days: Int64 = 0
    ) {
        self.lastMinute = lastMinute
        self.lastHour = lastHour
        self.lastDay = lastDay
        self.last30Days = last30Days
    }

    public static let zero = Self()
    public var isEmpty: Bool { last30Days == 0 }
}

public struct TokenUsageSeriesPoint: Equatable, Identifiable, Sendable {
    public var timestamp: Date
    public var tokens: Int64

    public init(timestamp: Date, tokens: Int64) {
        self.timestamp = timestamp
        self.tokens = tokens
    }

    public var id: Date { timestamp }
}

public struct TokenUsageBreakdown: Equatable, Identifiable, Sendable {
    public var routeID: UUID?
    public var endpointID: UUID?
    public var tokens: Int64
    public var requestCount: Int

    public init(routeID: UUID?, endpointID: UUID?, tokens: Int64, requestCount: Int) {
        self.routeID = routeID
        self.endpointID = endpointID
        self.tokens = tokens
        self.requestCount = requestCount
    }

    public var id: String {
        "\(routeID?.uuidString ?? "unknown-route"): \(endpointID?.uuidString ?? "unknown-endpoint")"
    }
}

public struct TokenUsageReport: Equatable, Sendable {
    public var startDate: Date
    public var endDate: Date
    public var totalTokens: Int64
    public var requestCount: Int
    public var series: [TokenUsageSeriesPoint]
    public var breakdowns: [TokenUsageBreakdown]

    public init(
        startDate: Date,
        endDate: Date,
        totalTokens: Int64,
        requestCount: Int,
        series: [TokenUsageSeriesPoint],
        breakdowns: [TokenUsageBreakdown]
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.totalTokens = totalTokens
        self.requestCount = requestCount
        self.series = series
        self.breakdowns = breakdowns
    }

    public var averageTokensPerRequest: Int64 {
        requestCount == 0 ? 0 : totalTokens / Int64(requestCount)
    }

    public var peakBucketTokens: Int64 {
        series.map(\.tokens).max() ?? 0
    }

    /// Returns the closest chronological series point in O(log n). Reports
    /// produced by `TokenUsageStore` always keep `series` sorted by timestamp.
    public func point(nearestTo timestamp: Date) -> TokenUsageSeriesPoint? {
        guard !series.isEmpty else { return nil }
        var lowerBound = 0
        var upperBound = series.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if series[middle].timestamp < timestamp {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        if lowerBound == 0 { return series[0] }
        if lowerBound == series.count { return series[series.count - 1] }
        let earlier = series[lowerBound - 1]
        let later = series[lowerBound]
        return timestamp.timeIntervalSince(earlier.timestamp)
            <= later.timestamp.timeIntervalSince(timestamp) ? earlier : later
    }
}

public actor TokenUsageStore {
    public let fileURL: URL

    private struct Record: Codable, Sendable {
        var timestamp: Date
        var tokens: Int64
        var routeID: UUID?
        var endpointID: UUID?
    }

    private struct BreakdownKey: Hashable {
        var routeID: UUID?
        var endpointID: UUID?
    }

    private var records: [Record]?
    /// Saturating cumulative token totals. Element zero is always 0; element
    /// `n` contains the total of the first `n` chronological records.
    private var prefixTokenTotals: [Int64] = [0]
    private var writesSinceCompaction = 0
    private var writesSinceSync = 0
    private var appendHandle: FileHandle?
    private var directoryPrepared = false
    private var nextPruneAt = Date.distantPast
    private var lastCompactionAt: Date?

    private static let syncInterval = 64
    private static let compactionWriteInterval = 16_384
    private static let maintenanceInterval: TimeInterval = 60 * 60

    public init(fileURL: URL = TokenUsageStore.defaultURL()) {
        self.fileURL = fileURL
    }

    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["MODELMOOR_USAGE"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ModelMoor", isDirectory: true)
            .appendingPathComponent("token-usage.jsonl")
        #else
        return PlatformPaths.dataHome(environment: environment)
            .appendingPathComponent("modelmoor", isDirectory: true)
            .appendingPathComponent("token-usage.jsonl")
        #endif
    }

    @discardableResult
    public func record(
        tokens: Int64,
        routeID: UUID? = nil,
        endpointID: UUID? = nil,
        at timestamp: Date = Date()
    ) throws -> TokenUsageSnapshot {
        try appendUsage(
            tokens: tokens,
            routeID: routeID,
            endpointID: endpointID,
            at: timestamp
        )
        return try snapshot(now: timestamp)
    }

    /// Persists a usage event without recalculating all rolling windows.
    /// Use this on request hot paths and obtain snapshots separately at UI cadence.
    public func appendUsage(
        tokens: Int64,
        routeID: UUID? = nil,
        endpointID: UUID? = nil,
        at timestamp: Date = Date()
    ) throws {
        guard tokens > 0 else { return }
        try loadIfNeeded(now: timestamp)
        let record = Record(
            timestamp: timestamp,
            tokens: tokens,
            routeID: routeID,
            endpointID: endpointID
        )
        if let lastTimestamp = records?.last?.timestamp, timestamp < lastTimestamp {
            let insertionIndex = firstRecordIndex(after: timestamp)
            records?.insert(record, at: insertionIndex)
            rebuildPrefixTokenTotals()
        } else {
            records?.append(record)
            prefixTokenTotals.append(addingClamped(prefixTokenTotals.last ?? 0, tokens))
        }
        try append(record)
        writesSinceCompaction += 1
        let compactionDue = lastCompactionAt.map {
            timestamp.timeIntervalSince($0) >= Self.maintenanceInterval
        } ?? true
        if writesSinceCompaction >= Self.compactionWriteInterval, compactionDue {
            try compact(now: timestamp)
        }
    }

    public func snapshot(now: Date = Date()) throws -> TokenUsageSnapshot {
        try loadIfNeeded(now: now)
        return aggregate(now: now)
    }

    public func report(
        from startDate: Date,
        to endDate: Date = Date(),
        bucketInterval: TimeInterval,
        routeID: UUID? = nil,
        endpointID: UUID? = nil
    ) throws -> TokenUsageReport {
        try Task.checkCancellation()
        guard startDate <= endDate, bucketInterval >= 1 else {
            throw TokenUsageStoreError.invalidReportRange
        }
        let bucketCount = Int(ceil(endDate.timeIntervalSince(startDate) / bucketInterval)) + 1
        guard bucketCount <= 4_096 else { throw TokenUsageStoreError.invalidReportRange }

        try loadIfNeeded(now: endDate)
        try Task.checkCancellation()
        let firstBucketInterval = floor(startDate.timeIntervalSince1970 / bucketInterval) * bucketInterval
        let firstBucket = Date(timeIntervalSince1970: firstBucketInterval)
        let seriesCount = Int(floor(endDate.timeIntervalSince(firstBucket) / bucketInterval)) + 1
        var seriesTotals = [Int64](repeating: 0, count: seriesCount)

        var totalTokens: Int64 = 0
        var requestCount = 0
        var breakdownTotals: [BreakdownKey: (tokens: Int64, requestCount: Int)] = [:]
        let startIndex = firstRecordIndex(atOrAfter: startDate)
        let endIndex = firstRecordIndex(after: endDate)
        for (index, record) in (records ?? [])[startIndex..<endIndex].enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            if let routeID, record.routeID != routeID { continue }
            if let endpointID, record.endpointID != endpointID { continue }

            totalTokens = addingClamped(totalTokens, record.tokens)
            requestCount += 1
            let offset = floor(record.timestamp.timeIntervalSince(firstBucket) / bucketInterval) * bucketInterval
            let bucketIndex = Int(offset / bucketInterval)
            if seriesTotals.indices.contains(bucketIndex) {
                seriesTotals[bucketIndex] = addingClamped(seriesTotals[bucketIndex], record.tokens)
            }

            let key = BreakdownKey(routeID: record.routeID, endpointID: record.endpointID)
            let current = breakdownTotals[key] ?? (tokens: 0, requestCount: 0)
            breakdownTotals[key] = (
                tokens: addingClamped(current.tokens, record.tokens),
                requestCount: current.requestCount + 1
            )
        }

        try Task.checkCancellation()

        let series = seriesTotals.enumerated().map { index, tokens in
            TokenUsageSeriesPoint(
                timestamp: firstBucket.addingTimeInterval(Double(index) * bucketInterval),
                tokens: tokens
            )
        }
        let unsortedBreakdowns: [TokenUsageBreakdown] = breakdownTotals.map { entry in
            let key = entry.key
            let value = entry.value
            return TokenUsageBreakdown(
                routeID: key.routeID,
                endpointID: key.endpointID,
                tokens: value.tokens,
                requestCount: value.requestCount
            )
        }
        let breakdowns = unsortedBreakdowns.sorted { lhs, rhs in
            lhs.tokens == rhs.tokens ? lhs.id < rhs.id : lhs.tokens > rhs.tokens
        }
        try Task.checkCancellation()
        return TokenUsageReport(
            startDate: startDate,
            endDate: endDate,
            totalTokens: totalTokens,
            requestCount: requestCount,
            series: series,
            breakdowns: breakdowns
        )
    }

    private func loadIfNeeded(now: Date) throws {
        guard records == nil else {
            performMaintenanceIfNeeded(now: now)
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            prefixTokenTotals = [0]
            nextPruneAt = now.addingTimeInterval(Self.maintenanceInterval)
            lastCompactionAt = now
            return
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        records = data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(Record.self, from: Data(line))
        }
        records?.sort { $0.timestamp < $1.timestamp }
        rebuildPrefixTokenTotals()
        let originalCount = records?.count ?? 0
        prune(now: now)
        if records?.count != originalCount { try compact(now: now) }
        nextPruneAt = now.addingTimeInterval(Self.maintenanceInterval)
        lastCompactionAt = now
    }

    private func performMaintenanceIfNeeded(now: Date) {
        guard now >= nextPruneAt else { return }
        prune(now: now)
        nextPruneAt = now.addingTimeInterval(Self.maintenanceInterval)
    }

    private func aggregate(now: Date) -> TokenUsageSnapshot {
        let minute = now.addingTimeInterval(-60)
        let hour = now.addingTimeInterval(-60 * 60)
        let day = now.addingTimeInterval(-24 * 60 * 60)
        let month = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let endIndex = firstRecordIndex(after: now)
        return TokenUsageSnapshot(
            lastMinute: tokenTotal(from: firstRecordIndex(atOrAfter: minute), to: endIndex),
            lastHour: tokenTotal(from: firstRecordIndex(atOrAfter: hour), to: endIndex),
            lastDay: tokenTotal(from: firstRecordIndex(atOrAfter: day), to: endIndex),
            last30Days: tokenTotal(from: firstRecordIndex(atOrAfter: month), to: endIndex)
        )
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-31 * 24 * 60 * 60)
        let expiredCount = firstRecordIndex(atOrAfter: cutoff)
        if expiredCount > 0 {
            records?.removeFirst(expiredCount)
            rebuildPrefixTokenTotals()
        }
    }

    private func rebuildPrefixTokenTotals() {
        prefixTokenTotals = [0]
        prefixTokenTotals.reserveCapacity((records?.count ?? 0) + 1)
        for record in records ?? [] {
            prefixTokenTotals.append(addingClamped(prefixTokenTotals.last ?? 0, record.tokens))
        }
    }

    private func tokenTotal(from startIndex: Int, to endIndex: Int) -> Int64 {
        guard startIndex < endIndex,
              prefixTokenTotals.indices.contains(startIndex),
              prefixTokenTotals.indices.contains(endIndex) else {
            return 0
        }
        let lowerTotal = prefixTokenTotals[startIndex]
        let upperTotal = prefixTokenTotals[endIndex]
        if upperTotal != Int64.max || lowerTotal == 0 {
            return upperTotal - lowerTotal
        }

        // A saturated prefix cannot be subtracted reliably. Extremely large
        // histories retain the previous clamped semantics via a rare fallback.
        var total: Int64 = 0
        for record in (records ?? [])[startIndex..<endIndex] {
            total = addingClamped(total, record.tokens)
        }
        return total
    }

    /// Index of the first record whose timestamp is greater than or equal to
    /// the target. The in-memory history is kept chronological on load/write.
    private func firstRecordIndex(atOrAfter target: Date) -> Int {
        guard let records else { return 0 }
        var lowerBound = 0
        var upperBound = records.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if records[middle].timestamp < target {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    /// Index of the first record whose timestamp is strictly greater than the
    /// target. Keeping equal timestamps together preserves inclusive reports.
    private func firstRecordIndex(after target: Date) -> Int {
        guard let records else { return 0 }
        var lowerBound = 0
        var upperBound = records.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if records[middle].timestamp <= target {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private func append(_ record: Record) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        var line = try encoder.encode(record)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw TokenUsageStoreError.writeFailed("Could not create the usage history file.")
            }
        }
        let handle: FileHandle
        if let appendHandle {
            handle = appendHandle
        } else {
            let replacement = try FileHandle(forWritingTo: fileURL)
            try replacement.seekToEnd()
            appendHandle = replacement
            handle = replacement
        }
        try handle.write(contentsOf: line)
        writesSinceSync += 1
        if writesSinceSync >= Self.syncInterval {
            try handle.synchronize()
            writesSinceSync = 0
        }
    }

    private func compact(now: Date) throws {
        prune(now: now)
        try prepareDirectory()
        if let appendHandle {
            try appendHandle.synchronize()
            try appendHandle.close()
            self.appendHandle = nil
            writesSinceSync = 0
        }
        let encoder = JSONEncoder()
        var data = Data()
        for record in records ?? [] {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if rename(temporary.path, fileURL.path) != 0 {
            let message = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw TokenUsageStoreError.writeFailed("Could not compact usage history: \(message)")
        }
        writesSinceCompaction = 0
        lastCompactionAt = now
    }

    private func prepareDirectory() throws {
        guard !directoryPrepared else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        directoryPrepared = true
    }

    private func addingClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}

public enum TokenUsageStoreError: LocalizedError {
    case writeFailed(String)
    case invalidReportRange

    public var errorDescription: String? {
        switch self {
        case let .writeFailed(message): message
        case .invalidReportRange: "The requested usage report range is invalid."
        }
    }
}

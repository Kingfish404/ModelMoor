import Foundation
import ModelMoorCore

public struct GatewayBudgetPeriodUsage: Equatable, Sendable, Identifiable {
    public var id: String
    public var resetsAt: Date
    public var tokens: Decimal
    public var amount: Decimal
    public var limit: ModelBudgetLimit
    public var usageUnknown: Bool
    public var storageFailed: Bool

    public var isBlocked: Bool {
        guard limit.tokens != nil || limit.amount != nil else { return false }
        return storageFailed || usageUnknown
            || limit.tokens.map { tokens >= Decimal($0) } == true
            || limit.amount.map { amount >= $0 } == true
    }
}

public final class GatewayBudgetLedger: @unchecked Sendable {
    private struct Bucket: Codable {
        var start: Date
        var tokens: Decimal = 0
        var amount: Decimal = 0
        var unknownUsage = false
    }

    private let lock = NSLock()
    private let fileURL: URL?
    private var buckets: [String: Bucket] = [:]
    private var failed = false

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                buckets = try JSONDecoder().decode([String: Bucket].self, from: Data(contentsOf: fileURL))
            } catch {
                failed = true
            }
        }
    }

    public func unavailable(_ route: ModelRouteConfiguration, now: Date = Date()) -> Bool {
        usage(for: route, now: now).contains(where: \.isBlocked)
    }

    public func usage(for route: ModelRouteConfiguration, now: Date = Date()) -> [GatewayBudgetPeriodUsage] {
        return lock.withLock {
            periods(route.budget ?? .init()).map { name, component, limit in
                let interval = calendar.dateInterval(of: component, for: now)!
                let bucket = buckets["\(route.id)/\(name)"].flatMap { $0.start == interval.start ? $0 : nil }
                return GatewayBudgetPeriodUsage(
                    id: name, resetsAt: interval.end,
                    tokens: bucket?.tokens ?? 0, amount: bucket?.amount ?? 0,
                    limit: limit, usageUnknown: bucket?.unknownUsage ?? false, storageFailed: failed
                )
            }
        }
    }

    public func record(
        route: ModelRouteConfiguration,
        tokens: Int64?,
        inputTokens: Int64?,
        outputTokens: Int64?,
        now: Date = Date()
    ) {
        lock.withLock {
            let budget = route.budget ?? ModelBudgetConfiguration()
            for (name, component, limit) in periods(budget) {
                let key = "\(route.id)/\(name)"
                let start = calendar.dateInterval(of: component, for: now)!.start
                var bucket = buckets[key].flatMap { $0.start == start ? $0 : nil } ?? Bucket(start: start)
                if let tokens { bucket.tokens += Decimal(tokens) }
                if let inputTokens, let outputTokens,
                   let inputPrice = budget.inputPricePerMillion,
                   let outputPrice = budget.outputPricePerMillion {
                    bucket.amount += (Decimal(inputTokens) * inputPrice + Decimal(outputTokens) * outputPrice) / 1_000_000
                } else if limit.amount != nil {
                    bucket.unknownUsage = true
                }
                if tokens == nil, limit.tokens != nil { bucket.unknownUsage = true }
                buckets[key] = bucket
            }
            guard let fileURL else { return }
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(buckets).write(to: fileURL, options: .atomic)
            } catch {
                failed = true
            }
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func periods(_ budget: ModelBudgetConfiguration) -> [(String, Calendar.Component, ModelBudgetLimit)] {
        [("daily", .day, budget.daily), ("weekly", .weekOfYear, budget.weekly), ("monthly", .month, budget.monthly)]
    }
}
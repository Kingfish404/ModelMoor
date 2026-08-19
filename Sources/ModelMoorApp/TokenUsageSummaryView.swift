import Foundation
import ModelMoorCore
import SwiftUI

struct TokenUsageSummaryView: View {
    let snapshot: TokenUsageSnapshot
    var title = "Unified API usage"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                Text("Upstream-reported tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                metricRow(metrics)
                VStack(spacing: 12) {
                    metricRow(Array(metrics.prefix(2)))
                    Divider()
                    metricRow(Array(metrics.suffix(2)))
                }
            }

            Text("Counts include requests whose upstream response contains usage data.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var metrics: [UsageMetricValue] {
        [
            UsageMetricValue(value: snapshot.lastMinute, label: "Last minute"),
            UsageMetricValue(value: snapshot.lastHour, label: "Last hour"),
            UsageMetricValue(value: snapshot.lastDay, label: "Last 24 hours"),
            UsageMetricValue(value: snapshot.last30Days, label: "Last 30 days")
        ]
    }

    private func metricRow(_ values: [UsageMetricValue]) -> some View {
        HStack(spacing: 18) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, metric in
                UsageMetric(metric: metric)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if index < values.count - 1 {
                    Divider().frame(height: 38)
                }
            }
        }
    }
}

private struct UsageMetricValue {
    var value: Int64
    var label: String
}

private struct UsageMetric: View {
    let metric: UsageMetricValue

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(TokenCountFormatter.compact(metric.value))
                .font(.title2.monospacedDigit().weight(.semibold))
            Text(metric.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.label), \(metric.value.formatted(.number.grouping(.automatic))) tokens")
    }
}

enum TokenCountFormatter {
    static func compact(_ value: Int64) -> String {
        let units: [(threshold: Int64, suffix: String)] = [
            (1_000_000_000_000, "T"),
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1_000, "K")
        ]
        guard let unit = units.first(where: { value >= $0.threshold }) else {
            return value.formatted(.number.grouping(.automatic))
        }
        let scaled = Double(value) / Double(unit.threshold)
        if scaled >= 100 {
            return scaled.formatted(.number.precision(.fractionLength(0))) + unit.suffix
        }
        return scaled.formatted(.number.precision(.fractionLength(0...1))) + unit.suffix
    }
}

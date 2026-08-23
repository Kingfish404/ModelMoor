import Charts
import ModelMoorCore
import ModelMoorSystem
import SwiftUI

struct UsageDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var timeRange: UsageTimeRange = .day
    @State private var routeID: UUID?
    @State private var endpointID: UUID?
    @State private var report: TokenUsageReport?
    @State private var selectedTimestamp: Date?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var loadGeneration: UInt64 = 0
    @State private var lastLoadedQuery: UsageQuery?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                filters
                summary
                trend
                breakdown
                privacyNote
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(28)
        }
        .navigationTitle("Usage")
        .refreshable { await reload(showProgress: false, query: query) }
        .task(id: refreshQuery) {
            guard model.isUIRefreshActive else { return }
            let requestedQuery = query
            let queryChanged = lastLoadedQuery != requestedQuery
            if queryChanged {
                selectedTimestamp = nil
            }
            await reload(showProgress: queryChanged || report == nil, query: requestedQuery)
        }
        .onChange(of: endpointID) { _, endpointID in
            guard let routeID,
                  let endpointID,
                  model.configuration.routes.first(where: { $0.id == routeID })?.endpointID != endpointID else {
                return
            }
            self.routeID = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model usage")
                .font(.largeTitle.weight(.semibold))
            Text("Inspect the tokens reported by models served through the Unified API.")
                .foregroundStyle(.secondary)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Time range", selection: $timeRange) {
                ForEach(UsageTimeRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                Picker("Model", selection: $routeID) {
                    Text("All models").tag(UUID?.none)
                    ForEach(availableRoutes) { route in
                        Text(route.publicModel).tag(Optional(route.id))
                    }
                }
                .frame(maxWidth: 300)

                Picker("API endpoint", selection: $endpointID) {
                    Text("All endpoints").tag(UUID?.none)
                    ForEach(model.configuration.endpoints.sorted(by: { $0.name < $1.name })) { endpoint in
                        Text(endpoint.name).tag(Optional(endpoint.id))
                    }
                }
                .frame(maxWidth: 300)

                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing usage")
                }
            }
        }
    }

    private var summary: some View {
        let metrics = [
            UsageHeadlineValue(label: "Total tokens", value: report?.totalTokens ?? 0),
            UsageHeadlineValue(label: "Requests", value: Int64(report?.requestCount ?? 0)),
            UsageHeadlineValue(label: "Average per request", value: report?.averageTokensPerRequest ?? 0),
            UsageHeadlineValue(label: "Peak per \(timeRange.bucketLabel)", value: report?.peakBucketTokens ?? 0)
        ]
        return HStack(spacing: 18) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
                UsageHeadlineMetric(metric: metric)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if index < metrics.count - 1 {
                    Divider().frame(height: 42)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var trend: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Token trend")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let point = selectedPoint {
                    Text("\(point.timestamp.formatted(timeRange.selectionFormat))  ·  \(point.tokens.formatted(.number.grouping(.automatic))) tokens")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if loadFailed {
                ContentUnavailableView(
                    "Usage history unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Refresh the panel to try loading it again.")
                )
                .frame(maxWidth: .infinity, minHeight: 250)
            } else if report?.totalTokens == 0 {
                ContentUnavailableView(
                    "No reported usage",
                    systemImage: "chart.xyaxis.line",
                    description: Text("No matching upstream response included token usage in this range.")
                )
                .frame(maxWidth: .infinity, minHeight: 250)
            } else if let report {
                Chart {
                    ForEach(report.series) { point in
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Tokens", point.tokens)
                        )
                        .foregroundStyle(
                            .linearGradient(
                                colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Tokens", point.tokens)
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.accentColor)
                    }

                    if let point = selectedPoint {
                        RuleMark(x: .value("Selected time", point.timestamp))
                            .foregroundStyle(.secondary.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        PointMark(
                            x: .value("Selected time", point.timestamp),
                            y: .value("Selected tokens", point.tokens)
                        )
                        .symbolSize(42)
                        .foregroundStyle(Color.accentColor)
                    }
                }
                .chartXSelection(value: $selectedTimestamp)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: timeRange.axisMarkCount)) {
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisTick().foregroundStyle(.tertiary)
                        AxisValueLabel(format: timeRange.axisFormat)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let tokens = value.as(Int64.self) {
                                Text(TokenCountFormatter.compact(tokens))
                            }
                        }
                    }
                }
                .frame(height: 260)
                .accessibilityLabel("Token usage over \(timeRange.accessibilityLabel)")
            }
        }
    }

    @ViewBuilder
    private var breakdown: some View {
        if let report, !report.breakdowns.isEmpty {
            let routeNames = Dictionary(
                uniqueKeysWithValues: model.configuration.routes.map { ($0.id, $0.publicModel) }
            )
            let endpointNames = Dictionary(
                uniqueKeysWithValues: model.configuration.endpoints.map { ($0.id, $0.name) }
            )
            VStack(alignment: .leading, spacing: 12) {
                Text("Usage by model")
                    .font(.title2.weight(.semibold))

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 0) {
                    GridRow {
                        tableHeader("Model")
                        tableHeader("API endpoint")
                        tableHeader("Requests", alignment: .trailing)
                        tableHeader("Tokens", alignment: .trailing)
                    }
                    Divider().gridCellColumns(4)

                    ForEach(report.breakdowns) { item in
                        GridRow {
                            Text(verbatim: modelName(item.routeID, names: routeNames))
                                .lineLimit(1)
                            Text(verbatim: endpointName(item.endpointID, names: endpointNames))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(item.requestCount.formatted(.number.grouping(.automatic)))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(item.tokens.formatted(.number.grouping(.automatic)))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.vertical, 9)
                        Divider().gridCellColumns(4)
                    }
                }
            }
        }
    }

    private var privacyNote: some View {
        Text("Usage history stores timestamps, token totals, and internal route and endpoint identifiers. Prompts, responses, model names, headers, and API keys are not stored. Streaming requests appear only when the upstream sends usage data.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var availableRoutes: [ModelRouteConfiguration] {
        model.configuration.routes
            .filter { endpointID == nil || $0.endpointID == endpointID }
            .sorted { $0.publicModel < $1.publicModel }
    }

    private var query: UsageQuery {
        UsageQuery(timeRange: timeRange, routeID: routeID, endpointID: endpointID)
    }

    private var refreshQuery: UsageRefreshQuery {
        UsageRefreshQuery(
            query: query,
            isActive: model.isUIRefreshActive,
            lastMinute: model.tokenUsage.lastMinute,
            lastHour: model.tokenUsage.lastHour,
            lastDay: model.tokenUsage.lastDay,
            last30Days: model.tokenUsage.last30Days
        )
    }

    private var selectedPoint: TokenUsageSeriesPoint? {
        guard let selectedTimestamp else { return nil }
        return report?.point(nearestTo: selectedTimestamp)
    }

    private func reload(showProgress: Bool, query requestedQuery: UsageQuery) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        if showProgress { isLoading = true }
        defer {
            if showProgress, loadGeneration == generation {
                isLoading = false
            }
        }
        let endDate = Date()
        let value = await model.tokenUsageReport(
            from: endDate.addingTimeInterval(-requestedQuery.timeRange.duration),
            to: endDate,
            bucketInterval: requestedQuery.timeRange.bucketInterval,
            routeID: requestedQuery.routeID,
            endpointID: requestedQuery.endpointID
        )
        guard !Task.isCancelled, loadGeneration == generation else { return }
        if report != value {
            report = value
        }
        let failed = value == nil
        if loadFailed != failed {
            loadFailed = failed
        }
        lastLoadedQuery = requestedQuery
    }

    private func modelName(_ id: UUID?, names: [UUID: String]) -> String {
        guard let id else { return "Earlier usage" }
        return names[id] ?? "Removed model"
    }

    private func endpointName(_ id: UUID?, names: [UUID: String]) -> String {
        guard let id else { return "Unknown endpoint" }
        return names[id] ?? "Removed endpoint"
    }

    private func tableHeader(_ title: String, alignment: Alignment = .leading) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.vertical, 7)
    }
}

private struct UsageQuery: Hashable {
    var timeRange: UsageTimeRange
    var routeID: UUID?
    var endpointID: UUID?
}

private struct UsageRefreshQuery: Hashable {
    var query: UsageQuery
    var isActive: Bool
    var lastMinute: Int64
    var lastHour: Int64
    var lastDay: Int64
    var last30Days: Int64
}

private struct UsageHeadlineValue {
    var label: String
    var value: Int64
}

private struct UsageHeadlineMetric: View {
    let metric: UsageHeadlineValue

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(TokenCountFormatter.compact(metric.value))
                .font(.title2.monospacedDigit().weight(.semibold))
            Text(metric.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.label), \(metric.value.formatted(.number.grouping(.automatic)))")
    }
}

private enum UsageTimeRange: String, CaseIterable, Identifiable {
    case minute
    case hour
    case day
    case week
    case month

    var id: Self { self }

    var title: String {
        switch self {
        case .minute: "1 min"
        case .hour: "1 hour"
        case .day: "24 hours"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .minute: 60
        case .hour: 60 * 60
        case .day: 24 * 60 * 60
        case .week: 7 * 24 * 60 * 60
        case .month: 30 * 24 * 60 * 60
        }
    }

    var bucketInterval: TimeInterval {
        switch self {
        case .minute: 5
        case .hour: 5 * 60
        case .day: 60 * 60
        case .week: 6 * 60 * 60
        case .month: 24 * 60 * 60
        }
    }

    var bucketLabel: String {
        switch self {
        case .minute: "5 sec"
        case .hour: "5 min"
        case .day: "hour"
        case .week: "6 hours"
        case .month: "day"
        }
    }

    var axisMarkCount: Int {
        switch self {
        case .minute, .hour: 6
        case .day: 7
        case .week, .month: 6
        }
    }

    var axisFormat: Date.FormatStyle {
        switch self {
        case .minute: .dateTime.second()
        case .hour, .day: .dateTime.hour().minute()
        case .week: .dateTime.weekday(.abbreviated).hour()
        case .month: .dateTime.month(.abbreviated).day()
        }
    }

    var selectionFormat: Date.FormatStyle {
        switch self {
        case .minute: .dateTime.hour().minute().second()
        case .hour, .day: .dateTime.hour().minute()
        case .week, .month: .dateTime.month(.abbreviated).day().hour().minute()
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .minute: "the last minute"
        case .hour: "the last hour"
        case .day: "the last 24 hours"
        case .week: "the last 7 days"
        case .month: "the last 30 days"
        }
    }
}

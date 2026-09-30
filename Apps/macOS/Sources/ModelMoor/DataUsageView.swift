import Charts
import ModelMoorCore
import ModelMoorSystem
import SwiftUI

struct DataUsageView: View {
    var refreshGeneration = 0
    @EnvironmentObject private var model: AppModel
    @State private var timeRange: UsageTimeRange = .day
    @State private var mappingID: UUID?
    @State private var report: DataUsageReport?
    @State private var failed = false
    @State private var selectedDate: Date?
    @State private var loadGeneration: UInt64 = 0

    private struct Query: Hashable {
        var range: UsageTimeRange
        var mapping: UUID?
        var active: Bool
        var refreshGeneration: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Data usage").font(.largeTitle.weight(.semibold))
                Text("Inspect traffic through your SSH forwarding paths.").foregroundStyle(.secondary)
            }
            Picker("Time range", selection: $timeRange) {
                ForEach(UsageTimeRange.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Picker("Forwarding path", selection: $mappingID) {
                Text("All paths").tag(UUID?.none)
                ForEach(model.configuration.tunnels) { tunnel in
                    ForEach(tunnel.mappings) { mapping in
                        Text(verbatim: pathName(mapping.id))
                            .tag(Optional(mapping.id))
                    }
                }
                ForEach(removedIDs, id: \.self) { id in
                    Text(verbatim: pathName(id)).tag(Optional(id))
                }
            }.frame(maxWidth: 600)

            if failed {
                ContentUnavailableView("Data history unavailable", systemImage: "exclamationmark.triangle", description: Text("History will be retried automatically."))
            } else if let report {
                HStack(spacing: 36) {
                    metric("Total data", bytes: report.sent.totalBytes + report.received.totalBytes)
                    metric("Sent", bytes: report.sent.totalBytes)
                    metric("Received", bytes: report.received.totalBytes)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Traffic trend").font(.title2.weight(.semibold))
                    if let selectedDate, let sent = report.sent.point(nearestTo: selectedDate),
                       let received = report.received.point(nearestTo: selectedDate) {
                        Text("\(sent.timestamp.formatted(timeRange.selectionFormat)) · Sent \(bytes(sent.bytes)) · Received \(bytes(received.bytes))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Chart {
                        ForEach(report.sent.series) { point in
                            LineMark(x: .value("Time", point.timestamp), y: .value("Bytes", point.bytes))
                                .foregroundStyle(by: .value("Direction", AppLocalization.string("Sent")))
                        }
                        ForEach(report.received.series) { point in
                            LineMark(x: .value("Time", point.timestamp), y: .value("Bytes", point.bytes))
                                .foregroundStyle(by: .value("Direction", AppLocalization.string("Received")))
                        }
                        if let selectedDate {
                            RuleMark(x: .value("Selected time", selectedDate)).foregroundStyle(.secondary)
                        }
                    }
                    .chartForegroundStyleScale([AppLocalization.string("Sent"): Color.blue, AppLocalization.string("Received"): Color.orange])
                    .chartXSelection(value: $selectedDate)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: timeRange.axisMarkCount)) {
                            AxisGridLine()
                            AxisValueLabel(format: timeRange.axisFormat)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let count = value.as(Int64.self) { Text(bytes(count)) }
                            }
                        }
                    }
                    .frame(height: 260)
                    .accessibilityLabel("Sent and received data over \(timeRange.accessibilityLabel)")
                    Text("Data transferred per \(timeRange.bucketLabel)").font(.caption).foregroundStyle(.secondary)
                }
                if pathIDs.isEmpty {
                    ContentUnavailableView("No recorded traffic", systemImage: "network", description: Text("Traffic appears here after an SSH forwarding path transfers data."))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Usage by forwarding path").font(.title2.weight(.semibold))
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                            GridRow {
                                Text("Forwarding path")
                                Text("Sent")
                                Text("Received")
                                Text("Total")
                            }.font(.caption).foregroundStyle(.secondary)
                            ForEach(pathIDs, id: \.self) { id in
                                let sent = report.sent.breakdowns.filter { $0.mappingID == id }.reduce(Int64(0)) { $0 + $1.bytes }
                                let received = report.received.breakdowns.filter { $0.mappingID == id }.reduce(Int64(0)) { $0 + $1.bytes }
                                GridRow {
                                    Button { mappingID = id } label: {
                                        Text(verbatim: pathName(id)).frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.link)
                                    Text(bytes(sent)).monospacedDigit()
                                    Text(bytes(received)).monospacedDigit()
                                    Text(bytes(sent + received)).monospacedDigit()
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView("Loading data usage…").frame(maxWidth: .infinity)
            }
            Text("Sent and received are relative to this Mac. Counts include forwarded TCP data and SOCKS negotiation, excluding SSH encryption and keepalives. History is sampled every 5 seconds and available for the last 30 days; earlier traffic cannot be recovered. Only timestamps, byte counts and internal path identifiers are stored.")
                .font(.caption).foregroundStyle(.secondary)

        }
        .task(id: Query(range: timeRange, mapping: mappingID, active: model.isUIRefreshActive, refreshGeneration: refreshGeneration)) {
            guard model.isUIRefreshActive else { return }
            report = nil
            selectedDate = nil
            repeat {
                await reload()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled
        }
    }

    private var pathIDs: [UUID] {
        Set((report?.sent.breakdowns ?? []).compactMap(\.mappingID) + (report?.received.breakdowns ?? []).compactMap(\.mappingID))
            .sorted { pathName($0) < pathName($1) }
    }

    private var removedIDs: [UUID] {
        let known = Set(model.configuration.tunnels.flatMap(\.mappings).map(\.id))
        return Set(pathIDs + [mappingID].compactMap { $0 }).subtracting(known).sorted { $0.uuidString < $1.uuidString }
    }

    private func pathName(_ id: UUID) -> String {
        for tunnel in model.configuration.tunnels {
            if let mapping = tunnel.mappings.first(where: { $0.id == id }) {
                let destination = mapping.direction.isDynamic ? "SOCKS" : "\(mapping.destinationHost):\(mapping.destinationPort)"
                return "\(tunnel.name) · \(mapping.name) · \(mapping.direction.rawValue) :\(mapping.listenPort) → \(destination)"
            }
        }
        return AppLocalization.string("Removed path") + " · \(id.uuidString.prefix(8))"
    }

    private func metric(_ title: LocalizedStringKey, bytes count: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bytes(count)).font(.title2.monospacedDigit().weight(.semibold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }

    private func reload() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let requestedRange = timeRange
        let requestedMapping = mappingID
        let end = Date()
        do {
            let value = try await model.session.dataUsageStore.report(from: end.addingTimeInterval(-timeRange.duration), to: end, bucketInterval: timeRange.bucketInterval, mappingID: mappingID)
            guard !Task.isCancelled, generation == loadGeneration, requestedRange == timeRange, requestedMapping == mappingID else { return }
            report = value
            failed = false
        } catch {
            guard !Task.isCancelled, generation == loadGeneration, requestedRange == timeRange, requestedMapping == mappingID else { return }
            failed = true
        }
    }
}

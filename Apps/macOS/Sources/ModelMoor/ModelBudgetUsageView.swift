import ModelMoorCore
import ModelMoorGateway
import SwiftUI

struct ModelBudgetUsageView: View {
    @EnvironmentObject private var model: AppModel
    let routes: [ModelRouteConfiguration]
    var showsAllPeriods = false
    var allowsEditing = true
    @State private var selectedPeriod = "daily"
    @State private var usage: [UUID: [GatewayBudgetPeriodUsage]] = [:]
    @State private var editingRoute: ModelRouteConfiguration?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Model budgets").font(.title2.weight(.semibold))
                Spacer()
                if !showsAllPeriods {
                    Picker("Budget period", selection: $selectedPeriod) {
                        Text("Daily").tag("daily")
                        Text("Weekly").tag("weekly")
                        Text("Monthly").tag("monthly")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }
            }
            ForEach(routes) { route in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(route.publicModel).font(.callout.monospaced()).textSelection(.enabled)
                        Spacer()
                        if usage[route.id]?.contains(where: \.isBlocked) == true {
                            Label("Budget paused", systemImage: "pause.circle.fill").foregroundStyle(.red)
                        }
                        if allowsEditing {
                            Button { editingRoute = route } label: { Image(systemName: "slider.horizontal.3") }
                                .buttonStyle(.borderless)
                                .help("Model budget")
                                .accessibilityLabel("Model budget")
                        }
                    }
                    if let periods = usage[route.id] {
                        ForEach(periods.filter { showsAllPeriods || $0.id == selectedPeriod }) { period in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(periodTitle(period.id)).font(.caption.weight(.semibold))
                                    Spacer()
                                    Text("Resets at").font(.caption)
                                    Text(period.resetsAt, format: .dateTime.month().day().hour().minute())
                                        .font(.caption.monospacedDigit())
                                }.foregroundStyle(.secondary)
                                if period.storageFailed {
                                    Label("Budget storage unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                                } else if period.usageUnknown {
                                    Label("Usage incomplete", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                }
                                ViewThatFits(in: .horizontal) {
                                    HStack(alignment: .top, spacing: 24) {
                                        tokenMetric(period).frame(minWidth: 190)
                                        amountMetric(period, route: route).frame(minWidth: 190)
                                    }
                                    VStack(alignment: .leading, spacing: 12) {
                                        tokenMetric(period)
                                        amountMetric(period, route: route)
                                    }
                                }
                                .opacity(period.storageFailed ? 0 : 1)
                                .accessibilityHidden(period.storageFailed)
                            }
                        }
                    } else {
                        ProgressView().controlSize(.small).accessibilityLabel("Refreshing usage")
                    }
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
        .task(id: routes) {
            while !Task.isCancelled {
                if model.isUIRefreshActive {
                    let result = await model.session.modelBudgetUsage(for: routes)
                    guard !Task.isCancelled else { return }
                    usage = result
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .sheet(item: $editingRoute) { route in
            ModelBudgetSheet(route: route).environmentObject(model)
        }
    }

    private func tokenMetric(_ period: GatewayBudgetPeriodUsage) -> some View {
        metric("Tokens", used: period.tokens, limit: period.limit.tokens.map { Decimal($0) }, currency: false)
    }

    @ViewBuilder
    private func amountMetric(_ period: GatewayBudgetPeriodUsage, route: ModelRouteConfiguration) -> some View {
        if route.budget?.inputPricePerMillion != nil, route.budget?.outputPricePerMillion != nil {
            metric("Amount limit (USD)", used: period.amount, limit: period.limit.amount, currency: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("USD").font(.caption).foregroundStyle(.secondary)
                Text("Pricing not configured").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ title: LocalizedStringKey, used: Decimal, limit: Decimal?, currency: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(formatted(used, currency: currency)).monospacedDigit()
                Text(verbatim: "/").foregroundStyle(.secondary)
                if let limit { Text(formatted(limit, currency: currency)).monospacedDigit() }
                else { Text("Unlimited").foregroundStyle(.secondary) }
            }.font(.callout)
            if let limit {
                let ratio = limit > 0 ? NSDecimalNumber(decimal: used / limit).doubleValue : 1
                ProgressView(value: min(max(ratio, 0), 1))
                    .tint(used >= limit ? .red : ratio >= 0.8 ? .orange : .accentColor)
                    .accessibilityLabel(title)
                    .accessibilityValue(Text(verbatim: "\(formatted(used, currency: currency)) / \(formatted(limit, currency: currency))"))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatted(_ value: Decimal, currency: Bool) -> String {
        currency ? value.formatted(.currency(code: "USD").precision(.fractionLength(2...6))) : value.formatted(.number)
    }

    private func periodTitle(_ id: String) -> LocalizedStringKey {
        switch id {
        case "weekly": "Weekly"
        case "monthly": "Monthly"
        default: "Daily"
        }
    }
}
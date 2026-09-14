import ModelMoorCore
import SwiftUI

struct ModelBudgetSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let route: ModelRouteConfiguration
    @State private var budget: ModelBudgetConfiguration
    @State private var errorMessage: String?
    @State private var saving = false

    init(route: ModelRouteConfiguration) {
        self.route = route
        _budget = State(initialValue: route.budget ?? .init())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Model budget").font(.title2)
            Text(route.publicModel).font(.body.monospaced())
            Form {
                Section("Daily") { limitFields($budget.daily) }
                Section("Weekly") { limitFields($budget.weekly) }
                Section("Monthly") { limitFields($budget.monthly) }
                Section("USD per million tokens") {
                    TextField("Input price", value: $budget.inputPricePerMillion, format: .number)
                    TextField("Output price", value: $budget.outputPricePerMillion, format: .number)
                }
                Section {
                    ModelBudgetUsageView(routes: [route], showsAllPeriods: true, allowsEditing: false)
                }
            }
            .formStyle(.grouped)
            if let errorMessage { Text(verbatim: errorMessage).foregroundStyle(.red) }
            HStack {
                Button("Remove all limits") {
                    budget.daily = .init()
                    budget.weekly = .init()
                    budget.monthly = .init()
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .disabled(saving)
        }
        .padding(24)
        .frame(width: 520, height: 650)
    }

    private func limitFields(_ limit: Binding<ModelBudgetLimit>) -> some View {
        Group {
            Toggle("Token limit", isOn: Binding(
                get: { limit.wrappedValue.tokens != nil },
                set: { limit.wrappedValue.tokens = $0 ? 1_000_000 : nil }
            ))
            if limit.wrappedValue.tokens != nil {
                TextField("Tokens", value: limit.tokens, format: .number.grouping(.never))
            }
            Toggle("Amount limit (USD)", isOn: Binding(
                get: { limit.wrappedValue.amount != nil },
                set: { limit.wrappedValue.amount = $0 ? 10 : nil }
            ))
            if limit.wrappedValue.amount != nil {
                TextField("USD", value: limit.amount, format: .number)
            }
        }
    }

    private func save() {
        do { try budget.validate() } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard let index = model.configuration.routes.firstIndex(where: { $0.id == route.id }) else { return }
        let previous = model.configuration.routes[index].budget
        model.configuration.routes[index].budget = budget
        saving = true
        Task {
            if await model.saveGateway() {
                dismiss()
            } else if let current = model.configuration.routes.firstIndex(where: { $0.id == route.id }) {
                model.configuration.routes[current].budget = previous
            }
            saving = false
        }
    }
}
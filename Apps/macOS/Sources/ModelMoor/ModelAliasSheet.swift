import ModelMoorCore
import SwiftUI

struct ModelAliasSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let route: ModelRouteConfiguration
    @State private var alias: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(route: ModelRouteConfiguration) {
        self.route = route
        _alias = State(initialValue: route.publicModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit Model Alias").font(.title2.weight(.semibold))
            Form {
                LabeledContent("Upstream model", value: route.upstreamModel)
                TextField("Public name", text: $alias)
            }
            if let saveError {
                Text(verbatim: saveError).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") {
                    isSaving = true
                    Task {
                        if await model.renameRoute(route.id, publicModel: alias) {
                            dismiss()
                        } else {
                            saveError = model.errorMessage
                        }
                        isSaving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled(isSaving)
    }
}
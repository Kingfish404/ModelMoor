import ModelMoorCore
import SwiftUI

struct AddUnifiedModelsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var endpointID: UUID?
    @State private var selectedModels = Set<String>()
    @State private var publicNames: [String: String] = [:]
    @State private var manualModel = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Add models to Unified API")
                    .font(.title2.weight(.semibold))
                Picker("Source endpoint", selection: $endpointID) {
                    ForEach(eligibleEndpoints) { endpoint in
                        Text(endpoint.name).tag(Optional(endpoint.id))
                    }
                }

                if availableModels.isEmpty {
                    ContentUnavailableView {
                        Label("No discovered models", systemImage: "cube.transparent")
                    } description: {
                        Text("Refresh the endpoint or enter an upstream model ID manually.")
                    }
                } else {
                    List(availableModels, selection: $selectedModels) { remoteModel in
                        HStack {
                            Toggle(remoteModel.id, isOn: selectionBinding(remoteModel.id))
                            Spacer()
                            if selectedModels.contains(remoteModel.id) {
                                TextField("Public name", text: publicNameBinding(remoteModel.id))
                                    .frame(width: 220)
                            }
                        }
                        .tag(remoteModel.id)
                    }
                    .frame(minHeight: 220)
                }

                HStack {
                    TextField("Enter model ID manually", text: $manualModel)
                    Button("Add") {
                        let value = manualModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return }
                        selectedModels.insert(value)
                        publicNames[value] = value
                        manualModel = ""
                    }
                    .disabled(manualModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let duplicate = duplicatePublicName {
                    Label("Public model name “\(duplicate)” is already in use.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)

            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button(addButtonTitle) {
                    guard let endpointID else { return }
                    let routes = selectedModels.sorted().map {
                        (publicModel: publicNames[$0] ?? $0, upstreamModel: $0)
                    }
                    Task {
                        if await model.addRoutes(routes, endpointID: endpointID) { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(endpointID == nil || selectedModels.isEmpty || duplicatePublicName != nil || hasBlankName)
            }
            .padding(16)
        }
        .frame(width: 620, height: 520)
        .onAppear {
            if endpointID == nil,
               let preferred = model.preferredModelEndpointID,
               eligibleEndpoints.contains(where: { $0.id == preferred }) {
                endpointID = preferred
            } else {
                endpointID = endpointID ?? eligibleEndpoints.first?.id
            }
            model.preferredModelEndpointID = nil
        }
        .onChange(of: endpointID) { _, _ in
            selectedModels.removeAll()
            publicNames.removeAll()
        }
    }

    private var eligibleEndpoints: [APIEndpointConfiguration] {
        model.configuration.endpoints.filter { $0.enabled && $0.kind == .openAICompatible }
    }

    private var availableModels: [RemoteModelMetadata] {
        guard let endpointID else { return [] }
        return model.inspections[endpointID]?.models ?? []
    }

    private var addButtonTitle: String {
        selectedModels.count == 1 ? "Add 1 Model" : "Add \(selectedModels.count) Models"
    }

    private var existingPublicNames: Set<String> {
        Set(model.configuration.routes.filter(\.enabled).map { $0.publicModel.lowercased() })
    }

    private var duplicatePublicName: String? {
        var seen = existingPublicNames
        for modelID in selectedModels.sorted() {
            let name = (publicNames[modelID] ?? modelID).trimmingCharacters(in: .whitespacesAndNewlines)
            if !seen.insert(name.lowercased()).inserted { return name }
        }
        return nil
    }

    private var hasBlankName: Bool {
        selectedModels.contains { (publicNames[$0] ?? $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func selectionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedModels.contains(id) },
            set: { selected in
                if selected {
                    selectedModels.insert(id)
                    publicNames[id] = publicNames[id] ?? id
                } else {
                    selectedModels.remove(id)
                    publicNames[id] = nil
                }
            }
        )
    }

    private func publicNameBinding(_ id: String) -> Binding<String> {
        Binding(get: { publicNames[id] ?? id }, set: { publicNames[id] = $0 })
    }
}

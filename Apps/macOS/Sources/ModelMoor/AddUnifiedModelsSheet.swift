import ModelMoorApplication
import ModelMoorCore
import ModelMoorSystem
import SwiftUI

struct AddUnifiedModelsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var endpointID: UUID?
    @State private var selectedModels = Set<String>()
    @State private var publicNames: [String: String] = [:]
    @State private var manualModel = ""
    @State private var searchText = ""
    @State private var selectedOnly = false
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Add models to Unified API")
                    .font(.title2.weight(.semibold))
                Picker("Source endpoint", selection: $endpointID) {
                    ForEach(eligibleEndpoints) { endpoint in
                        Text(endpoint.name).tag(Optional(endpoint.id))
                    }
                }
                .disabled(isSaving)

                HStack {
                    TextField("Search models", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Selected only", isOn: $selectedOnly)
                        .toggleStyle(.checkbox)
                    Button {
                        guard let endpointID else { return }
                        Task { await model.inspectEndpoint(endpointID) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh models")
                    .accessibilityLabel("Refresh models")
                    .disabled(endpointID == nil || isRefreshing || isSaving)
                }

                HStack {
                    Text("\(selectedModels.count) selected")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if isRefreshing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Select visible") {
                        selectedModels.formUnion(visibleModelIDs)
                    }
                    .disabled(visibleModelIDs.isEmpty || isSaving)
                    Button("Clear selection") { selectedModels.removeAll() }
                        .disabled(selectedModels.isEmpty || isSaving)
                }

                if eligibleEndpoints.isEmpty {
                    ContentUnavailableView {
                        Label("No eligible endpoints", systemImage: "link")
                    } description: {
                        Text("Enable an OpenAI-compatible endpoint before adding models.")
                    }
                } else if availableModelIDs.isEmpty {
                    ContentUnavailableView {
                        Label("No discovered models", systemImage: "cube.transparent")
                    } description: {
                        Text("Refresh the endpoint or enter an upstream model ID manually.")
                    }
                } else if visibleModelIDs.isEmpty {
                    if selectedOnly && selectedModels.isEmpty {
                        ContentUnavailableView("No selected models", systemImage: "checklist")
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                } else {
                    List(visibleModelIDs, id: \.self) { modelID in
                        HStack {
                            Toggle(modelID, isOn: selectionBinding(modelID))
                            Spacer()
                            if selectedModels.contains(modelID) {
                                TextField("Public name", text: publicNameBinding(modelID))
                                    .frame(width: 220)
                                    .accessibilityLabel("Public name for \(modelID)")
                            }
                        }
                    }
                    .frame(height: 240)
                    .disabled(isSaving)
                }

                if let endpointID, let message = model.inspections[endpointID]?.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                HStack {
                    TextField("Enter model ID manually", text: $manualModel)
                    Button("Add") {
                        let value = manualModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return }
                        selectedModels.insert(value)
                        publicNames[value] = publicNames[value] ?? value
                        manualModel = ""
                        searchText = ""
                    }
                    .disabled(manualModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(endpointID == nil || isSaving)

                if let duplicate = duplicatePublicName {
                    Label("Public model name “\(duplicate)” is already in use.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            }

            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button(addButtonTitle) {
                    guard let endpointID else { return }
                    isSaving = true
                    saveError = nil
                    let routes = selectedModels.sorted().map {
                        (publicModel: (publicNames[$0] ?? $0).trimmingCharacters(in: .whitespacesAndNewlines), upstreamModel: $0)
                    }
                    Task {
                        defer { isSaving = false }
                        if await model.addRoutes(routes, endpointID: endpointID) { dismiss() }
                        else { saveError = model.errorMessage }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !eligibleEndpoints.contains { $0.id == endpointID } || selectedModels.isEmpty || duplicatePublicName != nil || hasBlankName)
            }
            .padding(16)
        }
        .frame(width: 680, height: 580)
        .interactiveDismissDisabled(isSaving)
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
            manualModel = ""
            saveError = nil
        }
    }

    private var eligibleEndpoints: [APIEndpointConfiguration] {
        model.configuration.endpoints.filter { $0.enabled && $0.kind == .openAICompatible }
    }

    private var availableModels: [RemoteModelMetadata] {
        guard let endpointID else { return [] }
        return model.inspections[endpointID]?.models ?? []
    }

    private var availableModelIDs: [String] {
        Set(availableModels.map(\.id)).union(publicNames.keys).union(selectedModels).sorted()
    }

    private var visibleModelIDs: [String] {
        let query = PresentationSearchQuery(searchText)
        return availableModelIDs.filter {
            (!selectedOnly || selectedModels.contains($0))
                && query.matches(fields: [$0, publicNames[$0] ?? $0])
        }
    }

    private var isRefreshing: Bool {
        endpointID.map { model.inspectingEndpointIDs.contains($0) } ?? false
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
                }
            }
        )
    }

    private func publicNameBinding(_ id: String) -> Binding<String> {
        Binding(get: { publicNames[id] ?? id }, set: { publicNames[id] = $0 })
    }
}

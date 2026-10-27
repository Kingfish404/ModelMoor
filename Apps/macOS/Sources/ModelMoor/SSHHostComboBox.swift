import AppKit
import ModelMoorCore
import ModelMoorSystem
import SwiftUI

struct SSHHostComboBox: NSViewRepresentable {
    @Binding var value: String
    let targets: [SSHHostTarget]

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.delegate = context.coordinator
        comboBox.completes = true
        comboBox.numberOfVisibleItems = 14
        comboBox.isEditable = true
        comboBox.placeholderString = "Choose from ~/.ssh/config or type a target"
        context.coordinator.updateItems(targets.map(\.alias), in: comboBox)
        comboBox.stringValue = value
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        context.coordinator.updateBinding($value)
        context.coordinator.updateItems(targets.map(\.alias), in: comboBox)
        if comboBox.stringValue != value {
            comboBox.stringValue = value
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate {
        @Binding private var value: String
        private var installedAliases: [String] = []
        private(set) var itemUpdateCount = 0

        init(value: Binding<String>) {
            _value = value
        }

        func updateBinding(_ binding: Binding<String>) {
            _value = binding
        }

        func updateItems(_ aliases: [String], in comboBox: NSComboBox) {
            guard installedAliases != aliases else { return }
            installedAliases = aliases
            itemUpdateCount += 1
            comboBox.removeAllItems()
            comboBox.addItems(withObjectValues: aliases)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            value = comboBox.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            value = comboBox.stringValue
        }
    }
}

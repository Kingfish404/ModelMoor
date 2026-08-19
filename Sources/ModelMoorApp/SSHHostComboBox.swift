import AppKit
import ModelMoorCore
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
        comboBox.addItems(withObjectValues: targets.map(\.alias))
        comboBox.stringValue = value
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        let aliases = targets.map(\.alias)
        let currentItems = (0..<comboBox.numberOfItems).compactMap {
            comboBox.itemObjectValue(at: $0) as? String
        }
        if currentItems != aliases {
            comboBox.removeAllItems()
            comboBox.addItems(withObjectValues: aliases)
        }
        if comboBox.stringValue != value {
            comboBox.stringValue = value
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        @Binding private var value: String

        init(value: Binding<String>) {
            _value = value
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

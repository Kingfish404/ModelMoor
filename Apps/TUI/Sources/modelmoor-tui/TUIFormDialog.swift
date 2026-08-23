@preconcurrency import TermKit
import ModelMoorSystem

/// A compact multi-field form for settings actions. Secret fields are masked
/// while editing and are returned only to the completion handler, never to a
/// rendered snapshot.
struct TUIFormField {
    let label: String
    let initialValue: String
    let isSecret: Bool

    init(_ label: String, _ initialValue: String = "", isSecret: Bool = false) {
        self.label = label
        self.initialValue = initialValue
        self.isSecret = isSecret
    }
}

enum TUITheme {
    static func apply(to view: View) {
        view.colorScheme = ColorScheme(
            normal: Application.makeAttribute(fore: .gray, back: .black),
            focus: Application.makeAttribute(fore: .black, back: .brightYellow),
            hotNormal: Application.makeAttribute(fore: .brightYellow, back: .black),
            hotFocus: Application.makeAttribute(fore: .black, back: .brightYellow)
        )
    }

    static var dialog: ColorScheme {
        ColorScheme(
            normal: Application.makeAttribute(fore: .black, back: .gray),
            focus: Application.makeAttribute(fore: .black, back: .brightYellow),
            hotNormal: Application.makeAttribute(fore: .black, back: .gray),
            hotFocus: Application.makeAttribute(fore: .black, back: .brightYellow)
        )
    }
}

enum TUIFormDialog {
    static func request(
        _ title: String,
        message: String? = nil,
        fields: [TUIFormField],
        completion: @escaping ([String]?) -> Void
    ) {
        let width = min(96, max(72, Application.top.bounds.width - 2))
        let labelWidth = fields.map(\.label.count).max() ?? 0
        let rowHeight = 2
        let messageRows = message?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
        let height = min(
            max(10, messageRows + fields.count * rowHeight + 7),
            max(10, Application.top.bounds.height - 2)
        )
        let dialog = ASCIIDialog(title: title, width: width, height: height, buttons: [])
        dialog.colorScheme = TUITheme.dialog

        var inputs: [TextField] = []
        for (index, field) in fields.enumerated() {
            let y = messageRows + 1 + index * rowHeight
            let label = Label(field.label)
            label.x = Pos.at(1)
            label.y = Pos.at(y)
            label.width = Dim.sized(labelWidth)
            dialog.addSubview(label)

            let input = TextField(field.initialValue)
            input.x = Pos.at(labelWidth + 3)
            input.y = Pos.at(y)
            input.width = Dim.fill(2)
            input.secret = field.isSecret
            input.colorScheme = TUITheme.dialog
            dialog.addSubview(input)
            inputs.append(input)
        }

        if let message {
            let label = Label(message)
            label.x = Pos.at(1)
            label.y = Pos.at(0)
            label.width = Dim.fill(2)
            dialog.addSubview(label)
        }

        var didComplete = false
        func finish(_ values: [String]?) {
            guard !didComplete else { return }
            didComplete = true
            Application.requestStop()
            completion(values)
        }

        let save = Button("Save")
        save.isDefault = true
        save.clicked = { _ in finish(inputs.map(\.text)) }
        let cancel = Button("Cancel")
        cancel.clicked = { _ in finish(nil) }
        dialog.addButton(save)
        dialog.addButton(cancel)
        dialog.closedCallback = { finish(nil) }
        Application.present(top: dialog)
    }
}

enum TUIMessageDialog {
    static func show(_ title: String, message: String, width: Int = 78, height: Int = 12) {
        let dialog = ASCIIDialog(title: title, width: width, height: height, buttons: [])
        dialog.colorScheme = TUITheme.dialog
        let text = CopyableTextView()
        text.isReadOnly = true
        text.x = Pos.at(1)
        text.y = Pos.at(1)
        text.width = Dim.fill(2)
        text.height = Dim.fill(3)
        text.text = message
        text.colorScheme = TUITheme.dialog
        text.onCopy = { value in
            Task.detached(priority: .userInitiated) {
                try? SystemClipboard.copy(value)
            }
        }
        dialog.addSubview(text)

        let close = Button("Close")
        close.isDefault = true
        close.clicked = { _ in Application.requestStop() }
        dialog.addButton(close)
        Application.present(top: dialog)
    }
}

/// TermKit's built-in copy buffer is process-local. Mirror a selected
/// read-only text region to the system clipboard so copied TUI text can be
/// pasted in other terminal applications. It intentionally does not enable
/// editing.
final class CopyableTextView: TextView {
    var onCopy: ((String) -> Void)?

    override func processKey(event: KeyEvent) -> Bool {
        let copiesSelection: Bool
        switch event.key {
        case .controlC:
            copiesSelection = true
        case .letter("w") where event.isAlt:
            copiesSelection = true
        default:
            copiesSelection = false
        }
        if event.key == .controlC {
            emacsKillRingSave()
            copySelectionToSystemClipboard()
            return true
        }
        let handled = super.processKey(event: event)
        if copiesSelection && handled {
            copySelectionToSystemClipboard()
        }
        return handled
    }

    private func copySelectionToSystemClipboard() {
        let value = Clipboard.contents
        guard !value.isEmpty else { return }
        onCopy?(value)
    }
}

/// Dialog inherits TermKit's Unicode window border. Keep modal command forms
/// in the same ASCII vocabulary as the main console.
private final class ASCIIDialog: Dialog {
    override func redraw(region: Rect, painter: Painter) {
        painter.attribute = colorScheme.normal
        painter.clear(bounds)
        let width = max(0, bounds.width)
        let height = max(0, bounds.height)
        guard width >= 2, height >= 2 else { return }

        let horizontal = "+" + String(repeating: "-", count: width - 2) + "+"
        painter.goto(col: 0, row: 0)
        painter.add(str: horizontal)
        for row in 1..<(height - 1) {
            painter.goto(col: 0, row: row)
            painter.add(str: "|")
            painter.goto(col: width - 1, row: row)
            painter.add(str: "|")
        }
        painter.goto(col: 0, row: height - 1)
        painter.add(str: horizontal)

        if let title, width > 4 {
            painter.goto(col: 2, row: 0)
            painter.add(str: " " + String(title.prefix(width - 4)) + " ")
        }
    }
}

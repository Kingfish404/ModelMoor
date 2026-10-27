import AppKit
import ModelMoorCore
import ModelMoorSystem
import SwiftUI

struct CopyableText: View {
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SelectableReadOnlyText(value: value)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy text")
            .accessibilityLabel("Copy text")
        }
    }
}

struct SelectableReadOnlyText: NSViewRepresentable {
    let value: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.isSelectable = true
        field.isEditable = false
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != value { field.stringValue = value }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let size = nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size?.height ?? nsView.intrinsicContentSize.height))
    }
}

enum SSHCommandPresentation {
    static func render(_ command: SSHCommand) -> String {
        ([command.executableURL.path] + command.arguments).map { argument in
            let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
            if !argument.isEmpty && argument.unicodeScalars.allSatisfy({ safe.contains($0) }) { return argument }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }.joined(separator: " ")
    }

    static func forwardPreview(_ mapping: PortMappingConfiguration, host: String) -> String {
        render(SSHCommand(executableURL: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: [
            "-N", mapping.direction.sshFlag, mapping.forwardingSpecification, host.isEmpty ? "<ssh-alias>" : host
        ]))
    }
}
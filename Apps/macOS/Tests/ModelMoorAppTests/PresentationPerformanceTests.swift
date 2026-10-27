@testable import ModelMoor
import AppKit
import ModelMoorSystem
import ModelMoorCore
import SwiftUI
import XCTest

final class PresentationPerformanceTests: XCTestCase {
    @MainActor
    func testReadOnlyCommandTextSupportsSelectionAndWrapsWithoutTruncation() throws {
        let command = Array(repeating: "-o ServerAliveInterval=15", count: 20).joined(separator: " ")
        let host = NSHostingView(rootView: SelectableReadOnlyText(value: command))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        host.layoutSubtreeIfNeeded()

        func textField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField { return field }
            return view.subviews.lazy.compactMap { textField(in: $0) }.first
        }

        let field = try XCTUnwrap(textField(in: host))
        XCTAssertTrue(field.isSelectable)
        XCTAssertFalse(field.isEditable)
        XCTAssertEqual(field.maximumNumberOfLines, 0)
        XCTAssertEqual(field.stringValue, command)
        let wrappedSize = try XCTUnwrap(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 280, height: 10_000)))
        XCTAssertGreaterThan(wrappedSize.height, 30)
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor())
        XCTAssertEqual(editor.selectedRange.length, command.utf16.count)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.selectedRange.length, command.utf16.count)
        window.endEditing(for: nil)
    }

    func testSSHCommandPreviewPreservesArgumentsAndIncludesForwardOptions() {
        let command = SSHCommand(executableURL: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: ["-S", "/tmp/my socket", "user's-host", "$(unsafe)"])
        XCTAssertEqual(SSHCommandPresentation.render(command), "/usr/bin/ssh -S '/tmp/my socket' 'user'\"'\"'s-host' '$(unsafe)'")
        let mapping = PortMappingConfiguration(name: "API", listenPort: 18888, destinationPort: 8888)
        let preview = SSHCommandPresentation.forwardPreview(mapping, host: "gpu")
        XCTAssertTrue(preview.contains("-N -L"))
        XCTAssertTrue(preview.contains(mapping.forwardingSpecification))
        XCTAssertTrue(preview.hasSuffix(" gpu"))
    }

    func testHealthRefreshDoesNotInvalidateSearchUnlessSearchableFieldsChange() {
        let endpointID = UUID()
        let original = EndpointInspection(endpointID: endpointID, url: nil, statusCode: 200, models: [.init(id: "first")], classification: .llmAPI)
        var refreshed = original
        refreshed.checkedAt = original.checkedAt.addingTimeInterval(15)
        refreshed.latencyMilliseconds = 123
        refreshed.errorMessage = "Temporarily unavailable"
        XCTAssertFalse(SidebarInspectionSearchChanges.containsChanges(from: [endpointID: original], to: [endpointID: refreshed]))
        refreshed.models = [.init(id: "second")]
        XCTAssertTrue(SidebarInspectionSearchChanges.containsChanges(from: [endpointID: original], to: [endpointID: refreshed]))
        refreshed = original
        refreshed.classification = .otherHTTPService
        XCTAssertTrue(SidebarInspectionSearchChanges.containsChanges(from: [endpointID: original], to: [endpointID: refreshed]))
        XCTAssertTrue(SidebarInspectionSearchChanges.containsChanges(from: [endpointID: original], to: [:]))
        let replacementID = UUID()
        XCTAssertTrue(SidebarInspectionSearchChanges.containsChanges(from: [endpointID: original], to: [replacementID: original]))
    }

    @MainActor
    func testSSHHostUpdatesReuseItemsAndWriteToCurrentBinding() {
        var previousValue = "previous"
        var currentValue = "current"
        let coordinator = SSHHostComboBox.Coordinator(value: Binding(
            get: { previousValue }, set: { previousValue = $0 }
        ))
        let comboBox = NSComboBox()
        let aliases = (0..<1_000).map { "host-\($0)" }
        for _ in 0..<100 { coordinator.updateItems(aliases, in: comboBox) }
        XCTAssertEqual(coordinator.itemUpdateCount, 1)
        XCTAssertEqual(comboBox.numberOfItems, 1_000)
        coordinator.updateItems(["replacement"], in: comboBox)
        XCTAssertEqual(coordinator.itemUpdateCount, 2)
        XCTAssertEqual(comboBox.numberOfItems, 1)
        coordinator.updateBinding(Binding(get: { currentValue }, set: { currentValue = $0 }))
        comboBox.stringValue = "edited"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: comboBox))
        XCTAssertEqual(previousValue, "previous")
        XCTAssertEqual(currentValue, "edited")
    }
}
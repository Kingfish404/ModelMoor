import AppKit
import SwiftUI
@testable import ModelMoor
import XCTest

final class KeyboardNavigationTests: XCTestCase {
    func testMainNavigationCommandsHaveUniqueShortcutsAndExpectedDestinations() {
        XCTAssertEqual(
            MainNavigationCommand.all.map(\.selection),
            [.overview, .gateway, .subscriptionAccounts, .usage, .settings]
        )
        XCTAssertEqual(
            MainNavigationCommand.all.map(\.shortcut),
            ["1", "2", "3", "4", "5"]
        )
        XCTAssertEqual(
            Set(MainNavigationCommand.all.map(\.shortcut)).count,
            MainNavigationCommand.all.count
        )
        XCTAssertTrue(MainNavigationCommand.all.allSatisfy { !$0.localizedTitle.isEmpty })
    }
}

@MainActor
final class SidebarSearchFocusTests: XCTestCase {
    func testFocusRequestIssuedBeforeMountAndRepeatedRequestFocusNativeSearchField() throws {
        _ = NSApplication.shared
        let coordinator = SidebarSearchFocusCoordinator()
        let search = SearchFocusHarnessModel()
        coordinator.requestFocus()

        let hostingController = NSHostingController(
            rootView: SearchFocusHarness(coordinator: coordinator, search: search)
        )
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: 500),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.orderFrontRegardless()
        defer { window.close() }

        XCTAssertTrue(waitUntil {
            self.allSearchFields(in: window).contains {
                $0.currentEditor() === window.firstResponder
            }
        })

        let searchField = try XCTUnwrap(findSearchField(in: window))

        search.text = "gpu cluster"
        XCTAssertTrue(window.makeFirstResponder(window.contentView))
        XCTAssertFalse(searchField.currentEditor() === window.firstResponder)

        coordinator.requestFocus()
        XCTAssertTrue(waitUntil {
            self.allSearchFields(in: window).contains {
                $0.currentEditor() === window.firstResponder
            }
        })
        XCTAssertEqual(search.text, "gpu cluster")
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func findSearchField(in window: NSWindow) -> NSSearchField? {
        allSearchFields(in: window).first
    }

    private func allSearchFields(in window: NSWindow) -> [NSSearchField] {
        var fields = window.contentView.map(allSearchFields(in:)) ?? []
        for item in window.toolbar?.items ?? [] {
            if let view = item.view {
                fields.append(contentsOf: allSearchFields(in: view))
            }
        }
        return fields
    }

    private func allSearchFields(in view: NSView) -> [NSSearchField] {
        var fields = (view as? NSSearchField).map { [$0] } ?? []
        for child in view.subviews {
            fields.append(contentsOf: allSearchFields(in: child))
        }
        return fields
    }
}

private struct SearchFocusHarness: View {
    @ObservedObject var coordinator: SidebarSearchFocusCoordinator
    @ObservedObject var search: SearchFocusHarnessModel

    var body: some View {
        NavigationSplitView {
            Text("Sidebar")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(SidebarSearchModifier(
                    text: $search.text,
                    coordinator: coordinator
                ))
        } detail: {
            Text("Detail")
        }
    }
}

private final class SearchFocusHarnessModel: ObservableObject {
    @Published var text = ""
}

import AppKit
@testable import ModelMoor
import XCTest

@MainActor
final class DirtyWindowCloseCoordinatorTests: XCTestCase {
    private final class DelegateHarness: NSObject, NSWindowDelegate {
        let coordinator: DirtyWindowCloseCoordinator

        init(coordinator: DirtyWindowCloseCoordinator) {
            self.coordinator = coordinator
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            coordinator.shouldClose(sender)
        }
    }

    func testCleanWindowClosesThroughRealAppKitClosePath() {
        let drafts = DirtyDraftCoordinator()
        let (window, delegate) = makeWindow(drafts: drafts)
        withExtendedLifetime(delegate) {
            XCTAssertTrue(window.isVisible)
            window.performClose(nil)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testCancelKeepsRealWindowOpenAndDiscardClosesIt() {
        let drafts = DirtyDraftCoordinator()
        let draftID = DirtyDraftID.endpoint(UUID())
        drafts.register(id: draftID, title: "Endpoint", isDirty: true, apply: { true })
        let (window, delegate) = makeWindow(drafts: drafts)

        withExtendedLifetime(delegate) {
            window.performClose(nil)
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(drafts.prompt?.draftID, draftID)

            drafts.cancelPendingTransition()
            XCTAssertTrue(window.isVisible)

            window.performClose(nil)
            drafts.discardAndProceed()
            XCTAssertFalse(window.isVisible)
        }
    }

    func testFailedApplyKeepsRealWindowAndDirtyDraftOpen() async {
        let drafts = DirtyDraftCoordinator()
        let draftID = DirtyDraftID.connection(UUID())
        drafts.register(id: draftID, title: "Connection", isDirty: true, apply: { false })
        let (window, delegate) = makeWindow(drafts: drafts)

        window.performClose(nil)
        let task = drafts.applyAndProceed()
        await task?.value

        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(drafts.hasUnsavedChanges)
        withExtendedLifetime(delegate) {}
        window.delegate = nil
        window.close()
    }

    func testSuccessfulApplyClosesRealWindow() async {
        let drafts = DirtyDraftCoordinator()
        let draftID = DirtyDraftID.endpoint(UUID())
        var applyCount = 0
        drafts.register(id: draftID, title: "Endpoint", isDirty: true, apply: {
            applyCount += 1
            return true
        })
        let (window, delegate) = makeWindow(drafts: drafts)

        window.performClose(nil)
        await drafts.applyAndProceed()?.value

        XCTAssertEqual(applyCount, 1)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(drafts.hasUnsavedChanges)
        withExtendedLifetime(delegate) {}
    }

    private func makeWindow(
        drafts: DirtyDraftCoordinator
    ) -> (NSWindow, DelegateHarness) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        let delegate = DelegateHarness(
            coordinator: DirtyWindowCloseCoordinator(dirtyDrafts: drafts)
        )
        window.delegate = delegate
        window.orderFrontRegardless()
        return (window, delegate)
    }
}

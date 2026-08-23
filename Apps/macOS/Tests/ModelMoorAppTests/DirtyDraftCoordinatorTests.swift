@testable import ModelMoor
import XCTest

@MainActor
final class DirtyDraftCoordinatorTests: XCTestCase {
    private let endpointID = UUID()

    func testCleanEditorAllowsTransitionImmediately() {
        let coordinator = DirtyDraftCoordinator()
        var transitioned = false
        coordinator.register(
            id: .endpoint(endpointID),
            title: "Endpoint",
            isDirty: false,
            apply: { true }
        )

        coordinator.requestTransition { transitioned = true }

        XCTAssertTrue(transitioned)
        XCTAssertNil(coordinator.prompt)
    }

    func testCancelKeepsDirtyEditorAndSelection() {
        let coordinator = DirtyDraftCoordinator()
        var transitioned = false
        coordinator.register(
            id: .endpoint(endpointID),
            title: "Endpoint",
            isDirty: true,
            apply: { true }
        )

        coordinator.requestTransition { transitioned = true }
        XCTAssertEqual(coordinator.prompt?.draftID, .endpoint(endpointID))
        coordinator.cancelPendingTransition()

        XCTAssertFalse(transitioned)
        XCTAssertTrue(coordinator.hasUnsavedChanges)
        XCTAssertNil(coordinator.prompt)
    }

    func testDiscardPublishesResolutionAndContinues() {
        let coordinator = DirtyDraftCoordinator()
        var transitioned = false
        coordinator.register(
            id: .endpoint(endpointID),
            title: "Endpoint",
            isDirty: true,
            apply: { true }
        )

        coordinator.requestTransition { transitioned = true }
        coordinator.discardAndProceed()

        XCTAssertTrue(transitioned)
        XCTAssertFalse(coordinator.hasUnsavedChanges)
        XCTAssertEqual(coordinator.resolution?.draftID, .endpoint(endpointID))
        XCTAssertEqual(coordinator.resolution?.kind, .discarded)
    }

    func testMutationCommandWaitsForDirtyDecision() {
        let coordinator = DirtyDraftCoordinator()
        var mutationCount = 0
        coordinator.register(
            id: .endpoint(endpointID),
            title: "Endpoint",
            isDirty: true,
            apply: { true }
        )

        coordinator.requestTransition { mutationCount += 1 }
        XCTAssertEqual(mutationCount, 0)

        coordinator.discardAndProceed()
        XCTAssertEqual(mutationCount, 1)
    }

    func testFailedApplyPreservesDirtyEditorAndDoesNotContinue() async {
        let coordinator = DirtyDraftCoordinator()
        var transitioned = false
        coordinator.register(
            id: .endpoint(endpointID),
            title: "Endpoint",
            isDirty: true,
            apply: { false }
        )

        coordinator.requestTransition { transitioned = true }
        let applyTask = coordinator.applyAndProceed()
        XCTAssertTrue(coordinator.isApplying)
        // SwiftUI dismisses the alert after invoking its button action. That
        // dismissal must not cancel the transition already being applied.
        coordinator.cancelPendingTransition()
        await applyTask?.value

        XCTAssertFalse(transitioned)
        XCTAssertTrue(coordinator.hasUnsavedChanges)
        XCTAssertNil(coordinator.resolution)
        XCTAssertNil(coordinator.prompt)
    }

    func testSuccessfulApplyPublishesResolutionAndContinues() async {
        let coordinator = DirtyDraftCoordinator()
        var applyCount = 0
        var transitioned = false
        coordinator.register(
            id: .endpoint(endpointID),
            title: "Endpoint",
            isDirty: true,
            apply: {
                applyCount += 1
                return true
            }
        )

        coordinator.requestTransition { transitioned = true }
        await coordinator.applyAndProceed()?.value

        XCTAssertEqual(applyCount, 1)
        XCTAssertTrue(transitioned)
        XCTAssertFalse(coordinator.hasUnsavedChanges)
        XCTAssertEqual(coordinator.resolution?.kind, .applied)
    }
}

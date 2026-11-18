import XCTest

final class MeetTrainFlowTests: XCTestCase {
    @MainActor func testRiderSharesOnlyBookedIntermediateArrival() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        setReviewOrientation()
        let app = XCUIApplication()
        app.launchArguments = ["-AmtrakSignalGapQA", "-MeetArrivalBoardQA", "-preference.appearance", env["ROUNDHOUSE_REVIEW_APPEARANCE"] ?? "light"]
        app.launch()
        app.openSeededTrainDetailIfNeeded()
        let action = app.revealTrainAction("meetMyTrain")
        XCTAssertTrue(app.tapVisibleJourneyAction(action))
        XCTAssertTrue(app.navigationBars["Meet My Train"].waitForExistence(timeout: 6))
        let bookedStation = app.staticTexts["meetArrivalStation"].firstMatch
        XCTAssertTrue(bookedStation.waitForExistence(timeout: 5))
        XCTAssertEqual(bookedStation.label, "Baltimore Penn")
        XCTAssertFalse(app.buttons["meetArrivalStop"].exists)
        requestNativeCapture(role: "meet-arrival")
        let note = app.descendants(matching: .any).matching(identifier: "meetArrivalNote").firstMatch
        note.tap(); note.typeText("By the clock")
        let finishNote = app.buttons["meetFinishNote"].firstMatch
        if finishNote.isHittable { finishNote.tap() }
        let create = app.buttons["createArrivalBoard"]
        if !create.isHittable { app.swipeUp() }
        create.tap()
        let share = app.buttons["shareArrivalBoard"]
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        requestNativeCapture(role: "meet-arrival-ready")
        let nativePopover = app.popovers.firstMatch
        let alreadyShowingPopover = nativePopover.exists
        share.tap()
        XCTAssertTrue((!alreadyShowingPopover && nativePopover.waitForExistence(timeout: 3))
                      || app.otherElements["ShareSheet.RemoteContainerView"].firstMatch.waitForExistence(timeout: 2)
                      || app.collectionViews["activityCollectionView"].firstMatch.exists
                      || app.cells.matching(NSPredicate(format: "label == %@", "Copy")).firstMatch.exists
                      || app.otherElements["ActivityListView"].waitForExistence(timeout: 3)
                      || app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Copy'")).firstMatch.waitForExistence(timeout: 3)
                      || app.scrollViews["ActivityListView"].exists)
    }
}

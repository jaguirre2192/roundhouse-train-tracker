import XCTest

final class WindowSeatFlowTests: XCTestCase {
    @MainActor func testRiderBrowsesAnIllustratedLandmarkAndReturnsToTheTrain() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        setReviewOrientation()
        let app = XCUIApplication()
        app.launchArguments = ["-HudsonWindowQA", "-preference.appearance", env["ROUNDHOUSE_REVIEW_APPEARANCE"] ?? "light",
                               "-calendarSuggestions.v1.introductionDismissed", "YES"]
        app.launch()
        app.openSeededTrainDetailIfNeeded()
        let open = app.revealTrainAction("openWindowSeat")
        XCTAssertTrue(app.tapVisibleJourneyAction(open))
        let caption = app.staticTexts["windowSeatCaption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 6))
        XCTAssertEqual(caption.label, "Mid-Hudson Bridge")
        requestNativeCapture(role: "window-seat")
        let previous = app.buttons["Previous landmark"]
        if !previous.isHittable { app.swipeUp() }
        previous.tap()
        XCTAssertEqual(caption.label, "Hudson Highlands")
        let follow = app.buttons["windowSeatFollow"]
        XCTAssertTrue(follow.isEnabled)
        follow.tap()
        XCTAssertEqual(caption.label, "Mid-Hudson Bridge")
        let marker = app.buttons["landmark-bridge"]
        XCTAssertTrue(marker.isHittable)
        marker.tap()
        XCTAssertTrue(follow.isEnabled)
        let last = app.buttons["landmark-albany"]
        if last.exists && app.frame.contains(CGPoint(x: last.frame.midX, y: last.frame.midY)) {
            last.tap()
        } else {
            let print = app.descendants(matching: .any)["windowSeatPrint"].firstMatch
            let start = print.coordinate(withNormalizedOffset: .init(dx: 0.82, dy: 0.48))
            let end = print.coordinate(withNormalizedOffset: .init(dx: 0.18, dy: 0.48))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertEqual(caption.label, "Albany–Rensselaer")
        app.buttons["Close Window Seat"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 6))
    }
}

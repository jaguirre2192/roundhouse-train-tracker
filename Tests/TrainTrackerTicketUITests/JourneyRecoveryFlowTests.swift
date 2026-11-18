import XCTest

final class JourneyRecoveryFlowTests: XCTestCase {
    @MainActor
    func testMissedConnectionAlternativeCanBeFollowedFromOriginalTicket() {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        if (env["ROUNDHOUSE_TEST_ORIENTATION"] ?? env["TEST_RUNNER_ROUNDHOUSE_TEST_ORIENTATION"]) == "landscapeLeft" {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let appearance = env["ROUNDHOUSE_REVIEW_APPEARANCE"] ?? env["TEST_RUNNER_ROUNDHOUSE_REVIEW_APPEARANCE"] ?? "light"
        let app = XCUIApplication()
        app.launchArguments = ["-JourneyPlanPreview", "-JourneyPlanPreviewDetail", "-JourneyPlanPreviewOneWay",
                               "-ConnectionRecoveryQA", "-preference.appearance", appearance, "-preference.autoLockScreen", "NO",
                               "-calendarSuggestions.v1.enabled", "NO", "-calendarSuggestions.v1.introductionDismissed", "YES"]
        app.launch()
        let scroll = app.scrollViews.matching(NSPredicate(format: "identifier IN %@", ["journeyPlanSidePanel", "journeyPlanScroll"])).firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 12))
        let follow = app.buttons["followConnectionAlternative"]
        for _ in 0..<12 {
            let bounds = scroll.frame.insetBy(dx: 7, dy: 15)
            if follow.exists, bounds.contains(CGPoint(x: follow.frame.midX, y: follow.frame.midY)) { break }
            let start = scroll.coordinate(withNormalizedOffset: .init(dx: 0.48, dy: 0.76))
            let end = scroll.coordinate(withNormalizedOffset: .init(dx: 0.48, dy: 0.43))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(follow.isHittable)
        XCTAssertTrue(app.staticTexts["connectionAlternativeService"].label.contains("Eurocity Direct 9547"))
        requestNativeCapture(role: "connection-backup")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Brussels transfer and next reachable train"
        capture.lifetime = .keepAlways
        add(capture)
        follow.tap()
        XCTAssertTrue(app.buttons["viewFollowedAlternative"].waitForExistence(timeout: 8))
    }
}

import XCTest

@MainActor
final class LiveActivityRiderTests: XCTestCase {
    func testFreeRiderCanStartAndEndLiveActivityFromTheirSavedTrain() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppStorePreview", "-AppStorePreviewMap", "-AppStorePreviewTrack",
                               "-calendarSuggestions.v1.enabled", "NO"]
        app.launch()
        setReviewOrientation()
        XCTAssertTrue(app.staticTexts["journeyFocusStation"].waitForExistence(timeout: 12))
        app.expandJourneyPanel()
        let side = app.scrollViews["journeySidePanel"]
        let panel = side.exists ? side : app.scrollViews["journeyDrawerScroll"]
        let start = panel.buttons["Show on Lock Screen"]
        let stop = panel.buttons["End Live Activity"]
        for _ in 0..<18 {
            if start.isHittable || stop.isHittable { break }
            let from = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.77))
            let to = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.33))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        if stop.isHittable { stop.tap() }
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        start.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 12), "A free manual start should reach ActivityKit. \(app.alerts.firstMatch.exists ? app.alerts.firstMatch.label : "")")
        stop.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 8))
    }
}

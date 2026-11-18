import XCTest

final class JourneyRouteDisclosureTests: XCTestCase {
    @MainActor
    func testCountedStretchesOpenInPlaceAndTheirStopsCanBeSelectedOnTheMap() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppStorePreview", "-AppStorePreviewMap", "-AppStorePreviewTrack",
                               "-preference.appearance", "dark", "-preference.background", "white",
                               "-preference.autoLockScreen", "NO", "-calendarSuggestions.v1.enabled", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["journeyFocusStation"].waitForExistence(timeout: 12))
        app.expandJourneyPanel()
        let side = app.scrollViews["journeySidePanel"]
        let panel = side.exists ? side : app.scrollViews["journeyDrawerScroll"]
        let overview = panel.buttons["routeStopOverview"]
        let firstGap = panel.buttons["routeStopGap-us:gazetteer:NYP#1-us:gazetteer:WIL#3"]
        let secondGap = panel.buttons["routeStopGap-us:gazetteer:WIL#3-us:gazetteer:WAS#5"]
        let philadelphia = panel.buttons["routeStop-us:gazetteer:PHL#2"]
        let baltimore = panel.buttons["routeStop-us:gazetteer:BAL#4"]

        reveal(firstGap, in: panel)
        XCTAssertEqual(firstGap.label, "Show 1 intermediate stop")
        XCTAssertEqual(secondGap.label, "Show 1 intermediate stop")
        XCTAssertEqual(overview.label, "All 5 stops")
        XCTAssertFalse(philadelphia.exists)
        XCTAssertFalse(baltimore.exists)
        capture(app, "Train route with two counted stretches")
        firstGap.tap()
        XCTAssertTrue(philadelphia.waitForExistence(timeout: 3))
        XCTAssertFalse(firstGap.exists)
        XCTAssertTrue(secondGap.exists)
        XCTAssertFalse(baltimore.exists)
        XCTAssertEqual(overview.label, "Fewer stops")
        reveal(philadelphia, in: panel)
        requestNativeCapture(role: "route-stops")
        capture(app, "Philadelphia revealed on its stretch of the route")
        philadelphia.tap()
        // The phone lowers the drawer to show the chosen station on the map.
        app.expandJourneyPanel()
        reveal(philadelphia, in: panel)
        XCTAssertTrue(philadelphia.isSelected)
        XCTAssertEqual(app.staticTexts["journeyFocusStation"].label, "Wilmington")

        reveal(overview, in: panel)
        overview.tap()
        XCTAssertTrue(firstGap.waitForExistence(timeout: 3))
        XCTAssertTrue(secondGap.exists)
        XCTAssertFalse(philadelphia.exists)
        XCTAssertEqual(overview.label, "All 5 stops")
        overview.tap()
        XCTAssertTrue(philadelphia.waitForExistence(timeout: 3))
        XCTAssertTrue(baltimore.exists)
        XCTAssertFalse(firstGap.exists)
        XCTAssertFalse(secondGap.exists)
        XCTAssertEqual(overview.label, "Fewer stops")
    }

    @MainActor
    private func reveal(_ target: XCUIElement, in panel: XCUIElement) {
        for _ in 0..<16 {
            let viewport = panel.frame.insetBy(dx: 4, dy: 8)
            if target.exists, viewport.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)) {
                return
            }
            let up = !target.exists || target.frame.midY > viewport.midY
            let start = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.75 : 0.25))
            let end = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.30 : 0.70))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not reveal \(target.identifier) in the journey panel")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

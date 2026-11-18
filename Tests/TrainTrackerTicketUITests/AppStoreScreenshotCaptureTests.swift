import UIKit
import XCTest

/// Opt-in marketing captures of the real UI with isolated, illustrative journey fixtures.
/// The caller controls device, orientation, Duo posture and status-bar overrides.
final class AppStoreScreenshotCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureFiveMarketingScreens() throws {
        guard setting("ROUNDHOUSE_STORE_CAPTURE") == "1" else {
            throw XCTSkip("Set ROUNDHOUSE_STORE_CAPTURE=1 to export marketing screenshots")
        }
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let homeFixture = isPad ? ["-JourneyPlanPreview"] : ["-FirstRunPreview", "-AppStorePreviewTrack"]
        let app = launch(homeFixture)
        if isPad {
            XCTAssertTrue(app.descendants(matching: .any).matching(
                identifier: "defaultJourneyDetail-11111111-1111-1111-1111-111111111111"
            ).firstMatch.waitForExistence(timeout: 10))
        } else {
            XCTAssertTrue(app.buttons["followFirstRunTrain"].waitForExistence(timeout: 10))
        }
        capture(app, role: "map-home", settle: true)

        if isPad {
            launch(["-AppStorePreview", "-AppStorePreviewMap", "-AppStorePreviewTrack"], app: app)
        } else {
            let follow = app.buttons["followFirstRunTrain"]
            scrollTo(follow, in: app)
            XCTAssertTrue(follow.isHittable)
            follow.tap()
        }
        XCTAssertTrue(app.leadingTrain("us:amtraker:171:today").waitForExistence(timeout: 10))
        capture(app, role: "live-journey", settle: true)

        app.expandJourneyPanel()
        let route = app.staticTexts["Train Route"]
        scrollTo(route, in: app)
        XCTAssertTrue(route.isHittable, "The actual train route is reachable")
        let routePanel = app.scrollViews["journeySidePanel"].exists
            ? app.scrollViews["journeySidePanel"] : app.scrollViews["journeyDrawerScroll"]
        let stop = routePanel.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Wilmington")).firstMatch
        scrollTo(stop, in: app)
        XCTAssertTrue(stop.isHittable, "The seeded next stop is visible")
        capture(app, role: "train-stops")

        launch(["-JourneyPlanPreview", "-JourneyPlanPreviewDetail"], app: app)
        let routeTitle = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "Paris", "Amsterdam"
        )).firstMatch
        XCTAssertTrue(routeTitle.waitForExistence(timeout: 10), "A saved multi-train journey opens")
        let connection = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "Eurostar 9369"
        )).firstMatch
        scrollTo(connection, in: app)
        XCTAssertTrue(connection.isHittable, "The connection train is visible")
        capture(app, role: "connections")

        launch(homeFixture, app: app)
        let addJourney = app.homeAction("addJourneyFromTrips", timeout: 10)
        XCTAssertTrue(addJourney.isHittable)
        addJourney.tap()
        XCTAssertTrue(app.navigationBars["Add Journey"].waitForExistence(timeout: 5))
        let search = app.buttons["addJourneySearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable, "Search is the first visible intake choice")
        let photo = app.buttons["addJourneyPhoto"]
        if photo.exists {
            XCTAssertLessThan(search.frame.minY, photo.frame.minY)
        }
        capture(app, role: "add-journey")
        search.tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 5), "The highlighted action opens Search")
        XCTAssertFalse(app.navigationBars["Add Journey"].exists, "The intake sheet is dismissed")
    }

    private func setting(_ key: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        return environment[key] ?? environment["TEST_RUNNER_" + key]
    }

    @MainActor
    @discardableResult
    private func launch(_ fixture: [String], app existingApp: XCUIApplication? = nil) -> XCUIApplication {
        let app = existingApp ?? XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        let appearance = setting("ROUNDHOUSE_STORE_APPEARANCE") == "dark" ? "dark" : "light"
        app.launchArguments = fixture + [
            "-preference.appearance", appearance, "-preference.background", "white",
            "-preference.autoLockScreen", "NO", "-calendarSuggestions.v1.enabled", "NO",
            "-calendarSuggestions.v1.introductionDismissed", "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ]
        app.launch()
        let forwardingNotice = app.alerts["Forwarded Tickets"]
        if forwardingNotice.exists { forwardingNotice.buttons["OK"].tap() }
        return app
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<20 {
            let candidates = [
                app.scrollViews["journeySidePanel"], app.scrollViews["journeyDrawerScroll"],
                app.scrollViews["firstRunPanelScroll"],
            ]
            // On iPad the first scroll view is the library sidebar; the detail is trailing.
            let trailingScroll = app.scrollViews.allElementsBoundByIndex.max { $0.frame.maxX < $1.frame.maxX }
            let scroll = candidates.first(where: { $0.exists }) ?? trailingScroll ?? app
            // Duo's application frame can describe its inactive portrait display.
            // The scroll view carries the actual active viewport, including wide rows.
            let visible = scroll.frame.insetBy(dx: 8, dy: 8)
            if element.exists, element.isHittable, visible.contains(element.frame) { return }
            guard !visible.isEmpty else { break }
            let upward = !element.exists || element.frame.midY >= visible.midY
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.72 : 0.28))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.28 : 0.72))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, role: String, settle: Bool = false) {
        if settle { RunLoop.current.run(until: Date().addingTimeInterval(2)) }
        if let captureID = setting("ROUNDHOUSE_STORE_CAPTURE_ID"), !captureID.isEmpty {
            requestNativeCapture(role: role, sessionID: captureID)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = setting("ROUNDHOUSE_STORE_CAPTURE_ID") == nil ? role : "debug-\(role)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

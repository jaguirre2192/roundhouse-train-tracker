import UIKit
import XCTest

/// Past-only libraries exercise the real home and navigation without reading saved rider data.
final class HomeMapAndHistoryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testPastTrainsKeepMapHomeAndHistoryRoundTrip() throws {
        try requirePhone()
        let app = launch("-MyTripsPastOnlyQA")
        let panel = discoveryPanel(in: app)
        XCTAssertTrue(app.buttons["followFirstRunTrain"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["resumeImport"].exists, "The fixture has no unfinished imports")
        assertNoInlineHistory(in: panel)
        capture(app, "Past-only trains keep the map-led home")

        openHistory(in: app, panel: panel)
        let recent = app.buttons["individualTrain-eu:preview:time-bucket-9302"]
        scrollTo(recent, in: app.scrollViews["pastJourneysScroll"], app: app)
        XCTAssertTrue(recent.isHittable)
        XCTAssertTrue(app.buttons["individualTrain-eu:preview:time-bucket-9301"].exists)
        recent.tap()
        XCTAssertTrue(app.leadingTrain("eu:preview:time-bucket-9302").waitForExistence(timeout: 10))
        capture(app, "Saved past train opens from history")

        goBack(in: app)
        XCTAssertTrue(app.navigationBars["Past Journeys"].waitForExistence(timeout: 5))
        goBack(in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["followFirstRunTrain"].exists)
        if grabber(in: app).exists {
            XCTAssertEqual(grabber(in: app).value as? String, "Full height", "Returning keeps the expanded home panel")
        } else {
            assertLeadingPanel(panel, in: app)
        }
        assertNoInlineHistory(in: panel)
        capture(app, "History returns to the expanded map home")
    }

    @MainActor
    func testPastJourneySearchFiltersAndRecoversBeforeOpeningTheRightTrain() throws {
        try requirePhone()
        let app = launch("-MyTripsPastOnlyQA")
        openHistory(in: app, panel: discoveryPanel(in: app))
        let recent = app.buttons["individualTrain-eu:preview:time-bucket-9302"]
        let older = app.buttons["individualTrain-eu:preview:time-bucket-9301"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        XCTAssertTrue(older.exists)
        requestNativeCapture(role: "past-journeys")
        capture(app, "Past Journeys by boarding month")

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("9302")
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        XCTAssertTrue(older.waitForNonExistence(timeout: 5))

        field.typeText("x")
        let clear = app.buttons["clearPastJourneySearch"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(older.waitForExistence(timeout: 5))
        XCTAssertTrue(recent.exists)

        field.tap()
        field.typeText("9301")
        XCTAssertTrue(recent.waitForNonExistence(timeout: 5))
        older.tap()
        XCTAssertTrue(app.leadingTrain("eu:preview:time-bucket-9301").waitForExistence(timeout: 10))
    }

    @MainActor
    func testFindAConnectionInAMultiMonthArchive() throws {
        try requirePhone()
        let app = launch("-MyTripsPastPlansQA")
        openHistory(in: app, panel: discoveryPanel(in: app))
        let connectingJourney = app.buttons["pastJourney-77777777-7777-7777-7777-000000000003"]
        XCTAssertTrue(connectingJourney.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["October 2026"].exists)
        XCTAssertTrue(app.staticTexts["September 2026"].exists)
        requestNativeCapture(role: "archive-collection")
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("Bruxelles")
        XCTAssertTrue(connectingJourney.exists)
        XCTAssertFalse(app.buttons["pastJourney-77777777-7777-7777-7777-000000000000"].exists)
        connectingJourney.tap()
        XCTAssertTrue(app.navigationBars["Journey"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPastGroupedJourneyRemainsReachableAtLargestTextSize() throws {
        try requirePhone()
        let app = launch("-MyTripsPastPlansQA", largestText: true)
        let panel = discoveryPanel(in: app)
        XCTAssertTrue(app.buttons["followFirstRunTrain"].waitForExistence(timeout: 10))
        assertNoInlineHistory(in: panel)
        openHistory(in: app, panel: panel)

        let journey = app.buttons["pastJourney-77777777-7777-7777-7777-000000000003"]
        scrollTo(journey, in: app.scrollViews["pastJourneysScroll"], app: app)
        XCTAssertTrue(journey.isHittable, "The complete multi-train journey stays accessible")
        capture(app, "AX5 grouped journey in history")
        journey.tap()
        XCTAssertTrue(app.navigationBars["Journey"].waitForExistence(timeout: 5))
        let route = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "Paris Nord", "Amsterdam Centraal"
        )).firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 5), "History opens the saved passenger journey")
        capture(app, "AX5 saved grouped journey detail")
        goBack(in: app)
        XCTAssertTrue(app.navigationBars["Past Journeys"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNoFeaturedTrainKeepsInvitationActionsAndPastJourneys() throws {
        try requirePhone()
        let app = launch("-MyTripsPastOnlyQA", extra: ["-FirstRunPreviewEmpty"], largestText: true)
        let panel = discoveryPanel(in: app)
        XCTAssertFalse(app.buttons["followFirstRunTrain"].exists)
        XCTAssertTrue(app.staticTexts["No journeys right now"].waitForExistence(timeout: 5))
        expandPanel(in: app)
        let add = app.buttons["addJourneyEmptyState"]
        scrollTo(add, in: panel, app: app)
        XCTAssertTrue(add.isEnabled)
        XCTAssertTrue(panel.frame.contains(CGPoint(x: add.frame.midX, y: add.frame.midY)))
        capture(app, "AX5 invitation with saved past journeys")
        // Duo can report no computed hit point for the prominent SwiftUI button even
        // when it is visible. Exercise the actual touch and verify the resulting sheet.
        add.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let addBar = app.navigationBars["Add Journey"]
        XCTAssertTrue(addBar.waitForExistence(timeout: 5))
        addBar.buttons["Close"].tap()

        let search = app.buttons["searchTrainEmptyState"]
        scrollTo(search, in: panel, app: app)
        XCTAssertTrue(search.isEnabled)
        XCTAssertTrue(panel.frame.contains(CGPoint(x: search.frame.midX, y: search.frame.midY)))
        search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 5))
        goBack(in: app)
        openHistory(in: app, panel: panel)
        XCTAssertTrue(app.buttons["individualTrain-eu:preview:time-bucket-9302"].waitForExistence(timeout: 5))
        capture(app, "History remains reachable without a featured train")
    }

    @MainActor
    private func requirePhone() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "Compact phone home regression")
    }

    @MainActor
    private func launch(_ fixture: String, extra: [String] = [], largestText: Bool = false) -> XCUIApplication {
        if ProcessInfo.processInfo.environment["ROUNDHOUSE_TEST_ORIENTATION"] == "landscapeLeft" {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let app = XCUIApplication()
        let environment = ProcessInfo.processInfo.environment
        let appearance = environment["ROUNDHOUSE_REVIEW_APPEARANCE"] ?? environment["TEST_RUNNER_ROUNDHOUSE_REVIEW_APPEARANCE"] ?? "dark"
        app.launchArguments = [fixture, "-preference.appearance", appearance, "-preference.background", "white",
                               "-preference.autoLockScreen", "NO", "-calendarSuggestions.v1.enabled", "NO",
                               "-calendarSuggestions.v1.introductionDismissed", "YES"] + extra
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    @MainActor
    private func discoveryPanel(in app: XCUIApplication) -> XCUIElement {
        let panel = app.scrollViews["firstRunPanelScroll"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "Saved history keeps the discovery map and journey panel")
        if !grabber(in: app).exists { assertLeadingPanel(panel, in: app) }
        return panel
    }

    @MainActor
    private func grabber(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "journeyDrawerGrabber").firstMatch
    }

    @MainActor
    private func expandPanel(in app: XCUIApplication) {
        let handle = grabber(in: app)
        guard handle.exists else {
            assertLeadingPanel(app.scrollViews["firstRunPanelScroll"], in: app)
            return
        }
        for _ in 0..<2 where handle.value as? String != "Full height" { handle.tap() }
        XCTAssertEqual(handle.value as? String, "Full height")
    }

    @MainActor
    private func assertLeadingPanel(_ panel: XCUIElement, in app: XCUIApplication) {
        // Duo's XCTest application frame can report its inactive portrait surface. A host
        // run may supply the active display width measured by simctl, without resizing UI.
        let environment = ProcessInfo.processInfo.environment
        let measuredWidth = environment["ROUNDHOUSE_TEST_VIEWPORT_WIDTH"]
            ?? environment["TEST_RUNNER_ROUNDHOUSE_TEST_VIEWPORT_WIDTH"]
        let width = measuredWidth.flatMap { Double($0) }.map { CGFloat($0) } ?? app.frame.width
        XCTAssertGreaterThanOrEqual(width, 560, "Only roomy layouts replace the bottom sheet")
        XCTAssertLessThanOrEqual(panel.frame.maxX, app.frame.minX + width / 2, "The panel stays on the leading side of the crease")
        XCTAssertGreaterThan(panel.frame.height, 200, "The leading panel remains a usable scrolling column")
    }

    @MainActor
    private func assertNoInlineHistory(in panel: XCUIElement) {
        let savedRows = panel.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'individualTrain-' OR identifier BEGINSWITH 'pastJourney-'"
        ))
        XCTAssertEqual(savedRows.count, 0, "Completed journeys stay behind the history action")
    }

    @MainActor
    private func openHistory(in app: XCUIApplication, panel: XCUIElement) {
        expandPanel(in: app)
        assertNoInlineHistory(in: panel)
        let history = app.buttons["pastJourneysFromHome"]
        scrollTo(history, in: panel, app: app)
        XCTAssertTrue(history.isEnabled)
        XCTAssertTrue(panel.frame.contains(CGPoint(x: history.frame.midX, y: history.frame.midY)))
        history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Past Journeys"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["pastJourneysScroll"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in scroll: XCUIElement, app: XCUIApplication) {
        for _ in 0..<24 {
            // The active scroll view has the right viewport on Duo; app.frame can describe
            // its inactive portrait surface. Intersecting them can cause repeated drags
            // even when a full-width history row is already visible.
            let visible = scroll.frame.insetBy(dx: 8, dy: 8)
            if element.exists,
               visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let upward = !element.exists || element.frame.isEmpty || element.frame.midY >= visible.midY
            if upward { scroll.swipeUp(velocity: .slow) } else { scroll.swipeDown(velocity: .slow) }
        }
    }

    @MainActor
    private func goBack(in app: XCUIApplication) {
        // Duo places Back in its side toolbar, outside the navigation bar.
        let sideBack = app.buttons["BackButton"]
        let back = sideBack.exists ? sideBack : app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(back.isHittable)
        back.tap()
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

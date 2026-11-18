import UIKit
import XCTest

/// Layout regressions use in-memory preview journeys. They do not arm alerts, start a Live
/// Activity, read Calendar, or remove a saved journey.
final class JourneyLayoutPolishTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testEmptyFirstRunActionsRemainReachableAtLargestAccessibilitySize() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "The first-run map invitation belongs to compact My Trips")
        let app = launch("-FirstRunPreviewEmpty", largestText: true)
        let addJourney = app.buttons["addJourneyEmptyState"]
        scrollTo(addJourney, in: app)
        assertReachable(addJourney, in: app)
        capture(app, "AX5 first-run Add Journey clear of header")
        addJourney.tap()
        let addBar = app.navigationBars["Add Journey"]
        XCTAssertTrue(addBar.waitForExistence(timeout: 5), "The invitation opens Add Journey")
        addBar.buttons["Close"].tap()

        let search = app.buttons["searchTrainEmptyState"]
        scrollTo(search, in: app)
        assertReachable(search, in: app)
        capture(app, "AX5 first-run Search clear of header")
        search.tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 5), "The second invitation action opens train search")
        capture(app, "AX5 search opened from first-run panel")
    }

    @MainActor
    func testFollowingFeaturedTrainReachesSavedJourneyAndStops() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "The first-run map invitation belongs to compact My Trips")
        let app = launch("-FirstRunPreview")
        let follow = app.buttons["followFirstRunTrain"]
        scrollTo(follow, in: app)
        assertReachable(follow, in: app)
        capture(app, "Featured train before following")
        follow.tap()

        let savedTicket = app.leadingTrain("us:amtraker:171:today")
        XCTAssertTrue(savedTicket.waitForExistence(timeout: 10), "Follow replaces the invitation with the saved train")
        XCTAssertFalse(follow.exists)
        app.expandJourneyPanel()
        let route = app.staticTexts["Train Route"]
        scrollTo(route, in: app)
        assertReachable(route, in: app)
        let side = app.scrollViews["journeySidePanel"]
        let routePanel = side.exists ? side : app.scrollViews["journeyDrawerScroll"]
        let stop = routePanel.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Wilmington")).firstMatch
        scrollTo(stop, in: app)
        assertReachable(stop, in: app)
        capture(app, "Followed train with reachable route and stops")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Following a fixture does not request notification permission")
    }

    @MainActor
    func testJourneySupportActionsOpenTheirOwnPresentationsAndCancelSafely() {
        let app = launch("-AmtrakPositionQA")
        XCTAssertTrue(app.journeyRefresh.waitForExistence(timeout: 10))
        app.expandJourneyPanel()
        let attach = app.buttons["journeyAttachTicket"]
        scrollTo(attach, in: app)
        assertReachable(attach, in: app)
        capture(app, "Journey Attach Ticket reachable")
        attach.tap()
        let attachBar = app.navigationBars["Attach a Ticket"]
        XCTAssertTrue(attachBar.waitForExistence(timeout: 5), "Attach presents from the journey panel")
        capture(app, "Attach Ticket sheet from journey")
        attachBar.buttons["Close"].tap()

        let stop = app.buttons["stopTrackingFromJourney"]
        scrollTo(stop, in: app)
        assertReachable(stop, in: app)
        assertActionPair(in: app)
        capture(app, "Journey action pair before confirmation")
        stop.tap()
        let confirmation = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Stop Tracking", "stopTrackingFromJourney")).firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), "Stop Tracking requests confirmation")
        let cancel = app.buttons["Cancel"].firstMatch
        capture(app, "Stop Tracking confirmation without removing fixture")
        if cancel.exists {
            cancel.tap()
        } else {
            // Duo uses the system popover presentation, which dismisses outside its bounds.
            let dismissRegion = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismissRegion.waitForExistence(timeout: 5))
            dismissRegion.tap()
        }
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Cancel preserves the tracked journey and its actions")
        XCTAssertTrue(app.journeyRefresh.exists)
    }

    @MainActor
    func testJourneyActionPairReflowsAtLargestAccessibilitySize() {
        let app = launch("-AmtrakPositionQA", largestText: true)
        XCTAssertTrue(app.journeyRefresh.waitForExistence(timeout: 10))
        app.expandJourneyPanel()
        let stop = app.buttons["stopTrackingFromJourney"]
        scrollTo(stop, in: app)
        assertActionPair(in: app)
        capture(app, "AX5 journey actions share a deliberate grid")
    }

    @MainActor
    func testJourneyKeepsItsSelectionAndActionsAcrossRotation() {
        let app = launch("-AmtrakPositionQA")
        XCTAssertTrue(app.journeyRefresh.waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.expandJourneyPanel()
        let sidePanel = app.scrollViews["journeySidePanel"]
        if sidePanel.exists {
            capture(app, "Landscape rail before horizontal scrub")
            let start = sidePanel.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.72))
            let end = sidePanel.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.72))
            start.press(forDuration: 0.05, thenDragTo: end)
            capture(app, "Landscape rail after horizontal scrub")
        }
        let attach = app.buttons["journeyAttachTicket"]
        scrollTo(attach, in: app)
        capture(app, "Landscape attachment reachability before assertion")
        assertReachable(attach, in: app)
        let stop = app.buttons["stopTrackingFromJourney"]
        scrollTo(stop, in: app)
        assertActionPair(in: app)
        capture(app, "Landscape journey actions retain their selection and grid")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.journeyRefresh.waitForExistence(timeout: 5))
        XCTAssertTrue(stop.exists, "Resizing preserves the selected train and its management actions")
    }

    @MainActor
    private func launch(_ fixture: String, largestText: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            fixture,
            "-preference.appearance", "dark",
            "-preference.background", "white",
            "-preference.autoLockScreen", "NO",
            "-calendarSuggestions.v1.enabled", "NO",
            "-calendarSuggestions.v1.introductionDismissed", "YES",
        ]
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    /// Short drags keep nearby controls together and avoid skipping a target in a tall AX row.
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        _ = element.waitForExistence(timeout: 5)
        for _ in 0..<20 {
            if isFullyVisible(element, in: app) { return }
            let sidePanel = app.scrollViews["journeySidePanel"]
            if sidePanel.exists {
                let upward = !element.exists || element.frame.midY >= sidePanel.frame.midY
                let start = sidePanel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.72 : 0.28))
                let end = sidePanel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.28 : 0.72))
                start.press(forDuration: 0.05, thenDragTo: end)
                continue
            }
            let candidates = [
                app.scrollViews["firstRunPanelScroll"], app.scrollViews["journeyDrawerScroll"],
                app.scrollViews["journeySidePanel"], app.scrollViews.firstMatch,
            ]
            let scroll = candidates.first(where: { $0.exists }) ?? app
            let visible = scroll.frame.intersection(app.frame).insetBy(dx: 8, dy: 8)
            guard !visible.isEmpty else { break }
            let upward = !element.exists || element.frame.midY >= visible.midY
            let distance = min(180, visible.height * 0.28)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(
                dx: visible.midX - app.frame.minX,
                dy: visible.midY - app.frame.minY + (upward ? distance / 2 : -distance / 2)
            ))
            let end = start.withOffset(CGVector(dx: 0, dy: upward ? -distance : distance))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    @MainActor
    private func isFullyVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable, !element.frame.isEmpty,
              app.frame.insetBy(dx: -1, dy: -1).contains(element.frame) else { return false }
        let panel = [app.scrollViews["firstRunPanelScroll"], app.scrollViews["journeyDrawerScroll"], app.scrollViews["journeySidePanel"]]
            .first(where: { $0.exists })
        return panel.map { $0.frame.insetBy(dx: -1, dy: -1).contains(element.frame) } ?? true
    }

    @MainActor
    private func assertReachable(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(isFullyVisible(element, in: app), "\(element.label) is fully visible and tappable", file: file, line: line)
        for identifier in ["addJourneyFromTrips", "searchTrainsFromTrips", "settingsFromTrips", "moreFromTrips"] {
            let header = app.buttons[identifier]
            if header.exists, header.isHittable {
                XCTAssertFalse(element.frame.intersects(header.frame), "The panel control stays clear of \(identifier)", file: file, line: line)
            }
        }
    }

    @MainActor
    private func assertActionPair(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let share = app.buttons["Share Trip"].firstMatch
        let stop = app.buttons["stopTrackingFromJourney"]
        assertReachable(share, in: app, file: file, line: line)
        assertReachable(stop, in: app, file: file, line: line)
        let left = share.frame
        let right = stop.frame
        if abs(left.midY - right.midY) <= 2 {
            XCTAssertEqual(left.height, right.height, accuracy: 2, "Horizontal actions have equal heights", file: file, line: line)
            XCTAssertEqual(left.width, right.width, accuracy: 2, "Horizontal actions have equal widths", file: file, line: line)
            XCTAssertLessThanOrEqual(left.maxX, right.minX, "Horizontal actions do not overlap", file: file, line: line)
            let shareTitle = share.staticTexts["Share Trip"]
            let stopTitle = stop.staticTexts["Stop Tracking"]
            if shareTitle.exists, stopTitle.exists {
                XCTAssertEqual(shareTitle.frame.height, stopTitle.frame.height, accuracy: 2, "One horizontal title cannot wrap independently", file: file, line: line)
            }
        } else {
            XCTAssertEqual(left.minX, right.minX, accuracy: 2, "Stacked actions share their leading edge", file: file, line: line)
            XCTAssertEqual(left.maxX, right.maxX, accuracy: 2, "Stacked actions share their trailing edge", file: file, line: line)
            XCTAssertLessThanOrEqual(left.maxY, right.minY, "Stacked actions do not overlap", file: file, line: line)
        }
        let geometry = XCTAttachment(string: "Share Trip: \(left)\nStop Tracking: \(right)")
        geometry.name = "Journey action geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

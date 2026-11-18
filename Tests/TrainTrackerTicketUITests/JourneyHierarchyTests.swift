import XCTest

/// Exercise the real disclosure and stop navigation with isolated illustrative trains.
final class JourneyHierarchyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testNextStopLeadsAndFullTicketCanExpandAndCollapse() {
        let app = launch()
        let station = app.staticTexts["journeyFocusStation"]
        XCTAssertTrue(station.waitForExistence(timeout: 10))
        XCTAssertEqual(station.label, "Wilmington")
        let ticket = app.buttons["journeyTicket-us:amtraker:171:today"]
        XCTAssertTrue(ticket.waitForExistence(timeout: 5))
        XCTAssertLessThan(station.frame.maxY, ticket.frame.minY, "Next-stop guidance leads the route ticket")
        XCTAssertFalse(expandedTicket(in: app).exists)
        capture(app, "Next-stop guidance before compact route ticket")

        app.expandJourneyPanel()
        scrollTo(ticket, in: app)
        tap(ticket, in: app)
        let full = expandedTicket(in: app)
        XCTAssertTrue(full.waitForExistence(timeout: 5), "The route summary opens the full ticket")
        capture(app, "Expanded ticket retains the route line")
        scrollTo(ticket, in: app)
        tap(ticket, in: app)
        XCTAssertFalse(full.exists, "The ticket can return to a compact summary")
        XCTAssertTrue(app.staticTexts["journeyFocusStation"].exists)
    }

    @MainActor
    func testStopsStayReachableAfterCompactGuidance() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["journeyFocusStation"].waitForExistence(timeout: 10))
        let details = app.buttons["journeyExpandDetails"]
        if details.exists {
            XCTAssertEqual(details.value as? String, "Collapsed")
            XCTAssertFalse(app.staticTexts["Train Route"].exists, "Wide maps begin with a short guidance panel")
        }
        app.expandJourneyPanel()
        let route = app.staticTexts["Train Route"]
        scrollTo(route, in: app)
        XCTAssertTrue(route.exists)
        let stop = panel(in: app).buttons.matching(NSPredicate(format: "label CONTAINS %@", "Wilmington")).firstMatch
        scrollTo(stop, in: app)
        tap(stop, in: app)
        XCTAssertTrue(app.staticTexts["journeyFocusStation"].exists, "Stop selection retains this journey")
        capture(app, "Upcoming stop reached through Stops and details")
    }

    @MainActor
    func testLargestTextGuidanceAndTicketRemainReachable() {
        let app = launch(largestText: true)
        let station = app.staticTexts["journeyFocusStation"]
        if !station.waitForExistence(timeout: 3) {
            // At accessibility sizes a regular-width detail intentionally uses its wide
            // reading page, rather than squeezing the journey into a floating map panel.
            let hero = app.otherElements["liveTripTicketHero"]
            XCTAssertTrue(hero.waitForExistence(timeout: 5), "The reading fallback preserves the full ticket")
            let focus = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Wilmington")).firstMatch
            XCTAssertTrue(focus.exists, "The fallback retains the next-stop guidance")
            capture(app, "AX5 wide reading layout retains the journey")
            return
        }
        app.expandJourneyPanel()
        scrollTo(station, in: app)
        XCTAssertTrue(panel(in: app).frame.contains(station.frame), "The complete station name fits at AX5")
        capture(app, "AX5 next stop and stacked timing")
        let ticket = app.buttons["journeyTicket-us:amtraker:171:today"]
        scrollTo(ticket, in: app)
        tap(ticket, in: app)
        XCTAssertTrue(expandedTicket(in: app).waitForExistence(timeout: 5))
        capture(app, "AX5 full ticket remains available")
    }

    @MainActor
    private func launch(largestText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppStorePreview", "-AppStorePreviewMap", "-AppStorePreviewTrack",
                               "-preference.appearance", "dark", "-preference.background", "white",
                               "-preference.autoLockScreen", "NO", "-calendarSuggestions.v1.enabled", "NO"]
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    @MainActor
    private func expandedTicket(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "journeyExpandedTicket").firstMatch
    }

    @MainActor
    private func panel(in app: XCUIApplication) -> XCUIElement {
        let side = app.scrollViews["journeySidePanel"]
        return side.exists ? side : app.scrollViews["journeyDrawerScroll"]
    }

    @MainActor
    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication) {
        let scroll = panel(in: app)
        for _ in 0..<24 {
            let viewport = scroll.frame.insetBy(dx: 4, dy: 8)
            if target.exists, viewport.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)) { return }
            let up = !target.exists || target.frame.midY > viewport.midY
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.74 : 0.26))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.30 : 0.70))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Cannot reach \(target.label)")
    }

    @MainActor
    private func tap(_ target: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(target.exists && target.isEnabled)
        XCTAssertTrue(panel(in: app).frame.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)))
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

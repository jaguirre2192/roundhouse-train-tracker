import XCTest

final class RecentRouteSearchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testSearchBothStationsThenReuseAndClearTheRoute() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-FrictionlessIntakeQA", "-FrictionlessIntakeQAReset", "-WorkflowQANoAnimations",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
            "-preference.homeStation", "none",
        ]
        app.launch()
        let notice = app.alerts["Forwarded Tickets"]
        if notice.waitForExistence(timeout: 2) { notice.buttons["OK"].tap() }
        openSearch(app)

        let shortcut = app.buttons["useRecentJourneyRoute"]
        XCTAssertFalse(shortcut.exists)
        pick("Boston South Station", with: "Boston", for: "From", in: app)
        pick("New York Penn Station", with: "New York", for: "To", in: app)
        XCTAssertFalse(shortcut.exists)
        let search = app.buttons["Search Trains"]
        XCTAssertTrue(search.isEnabled && search.isHittable)
        search.tap()
        let result = app.descendants(matching: .any).matching(identifier: "journey-option-qa-2150").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        reopenSearch(app)

        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        requestNativeCapture(role: "recent-route")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Recent Route on the search landing"
        attachment.lifetime = .keepAlways
        add(attachment)
        let addReturn = app.switches["Add Return"]
        addReturn.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(addReturn.value as? String, "1")
        shortcut.tap()
        XCTAssertTrue(endpoint("From", in: app).label.contains("Boston South Station"))
        XCTAssertTrue(endpoint("To", in: app).label.contains("New York Penn Station"))
        XCTAssertEqual(addReturn.value as? String, "1")
        XCTAssertTrue(search.isEnabled)
        XCTAssertFalse(result.exists)
        XCTAssertFalse(shortcut.exists)

        reopenSearch(app)
        let historyMenu = app.buttons["recentJourneyRoutesMenu"]
        // Starting elsewhere keeps deliberate history available without suggesting a
        // conflicting pair. Choosing the route explicitly may replace both endpoints.
        pick("New York Penn Station", with: "New York", for: "From", in: app)
        XCTAssertFalse(shortcut.exists)
        XCTAssertTrue(historyMenu.waitForExistence(timeout: 5))
        XCTAssertFalse(search.isEnabled)
        historyMenu.tap()
        let away = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                                                    "Boston South Station", "New York Penn Station")).firstMatch
        XCTAssertTrue(away.waitForExistence(timeout: 5))
        away.tap()
        XCTAssertTrue(endpoint("From", in: app).label.contains("Boston South Station"))
        XCTAssertTrue(endpoint("To", in: app).label.contains("New York Penn Station"))
        XCTAssertTrue(search.isEnabled)
        XCTAssertFalse(historyMenu.exists)

        reopenSearch(app)
        XCTAssertTrue(historyMenu.waitForExistence(timeout: 5))
        historyMenu.tap()
        app.buttons["Clear Recent Routes"].tap()
        XCTAssertFalse(shortcut.exists)
        reopenSearch(app)
        XCTAssertFalse(shortcut.exists)
    }

    @MainActor
    private func openSearch(_ app: XCUIApplication) {
        let search = app.homeAction("searchTrainsFromTrips", timeout: 8)
        XCTAssertTrue(search.isHittable)
        search.tap()
        XCTAssertTrue(endpoint("From", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func reopenSearch(_ app: XCUIApplication) {
        let sideBack = app.buttons["BackButton"]
        let back = sideBack.exists ? sideBack : app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.isHittable)
        back.tap()
        openSearch(app)
    }

    @MainActor
    private func pick(_ station: String, with query: String, for role: String, in app: XCUIApplication) {
        endpoint(role, in: app).tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(query)
        let match = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", station)).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 8))
        match.tap()
        XCTAssertTrue(endpoint(role, in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func endpoint(_ role: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", role + ",")).firstMatch
    }
}

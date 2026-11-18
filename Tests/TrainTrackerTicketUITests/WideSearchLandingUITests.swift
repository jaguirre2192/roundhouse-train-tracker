import XCTest

/// Exercises the actual landing controls with fixture libraries; no provider lookup is made.
/// The caller retains the simulator's current orientation and Duo posture.
final class WideSearchLandingUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testWideColumnsKeepReturnAndDepartureWhenPlacePickerIsCancelled() throws {
        for appearance in ["light", "dark"] {
            let app = openSearch(appearance: appearance)
            let columns = element("journeySearchColumns", in: app)
            guard columns.waitForExistence(timeout: 5) else {
                throw XCTSkip("The active search canvas does not use wide columns")
            }
            // Form may flatten nested accessibility containers. Check the actual controls
            // and headings instead of depending on an intermediate VStack's AX node.
            let route = app.staticTexts["Route"]
            let timing = app.staticTexts["Outbound"]
            XCTAssertTrue(route.exists && timing.exists)
            XCTAssertEqual(route.frame.minY, timing.frame.minY, accuracy: 2)
            let from = placeButton("From,", in: app)
            let to = placeButton("To,", in: app)
            let outbound = app.staticTexts["Date and time"]
            XCTAssertTrue(outbound.exists)
            for place in [from, to] {
                XCTAssertTrue(place.isHittable)
                XCTAssertLessThanOrEqual(place.frame.maxX, outbound.frame.minX)
            }
            let search = app.buttons["Search Trains"]
            XCTAssertTrue(search.exists && search.isHittable, "Search is visible before scrolling")
            XCTAssertGreaterThanOrEqual(search.frame.minY, max(to.frame.maxY, outbound.frame.maxY))
            capture(app, "debug-wide-search-\(appearance)-before")

            let departureBefore = dateValues(in: app)
            XCTAssertFalse(departureBefore.isEmpty, "Read the actual selected departure value")
            let addReturn = app.switches["Add Return"]
            XCTAssertTrue(addReturn.isHittable)
            addReturn.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            XCTAssertEqual(addReturn.value as? String, "1")
            let returnDate = app.staticTexts["Return date and time"]
            XCTAssertTrue(returnDate.waitForExistence(timeout: 5), "Return exposes its native date picker")
            let returnBefore = dateValues(in: app)
            XCTAssertFalse(returnBefore.isEmpty)
            from.tap()
            XCTAssertTrue(app.navigationBars["Choose From"].waitForExistence(timeout: 5))
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.isHittable)
            cancel.tap()
            XCTAssertTrue(columns.waitForExistence(timeout: 5))
            XCTAssertEqual(addReturn.value as? String, "1", "Cancelling a station choice retains return travel")
            XCTAssertEqual(dateValues(in: app), returnBefore, "Both outbound and return values survive cancellation")
            XCTAssertTrue(Set(departureBefore).isSubset(of: Set(returnBefore)))
            capture(app, "debug-wide-search-\(appearance)-after-cancel")

            goBack(in: app)
            let addJourney = app.homeAction("addJourneyFromTrips")
            XCTAssertTrue(addJourney.isHittable, "Back restores the existing home")
            addJourney.tap()
            XCTAssertTrue(app.navigationBars["Add Journey"].waitForExistence(timeout: 5))
            app.buttons["Close"].firstMatch.tap()
            XCTAssertTrue(app.homeAction("addJourneyFromTrips").isHittable, "Close restores home")
            app.terminate()
        }
    }

    @MainActor
    func testLargestTextKeepsSingleColumnSearchAndReachableControls() {
        let app = openSearch(appearance: "dark", largestText: true)
        XCTAssertFalse(element("journeySearchColumns", in: app).exists)
        XCTAssertFalse(element("journeySearchTimingColumn", in: app).exists)
        XCTAssertTrue(placeButton("From,", in: app).isHittable)
        capture(app, "debug-search-dark-AX5-top")
        let addReturn = app.switches["Add Return"]
        scrollTo(addReturn, in: app)
        XCTAssertTrue(addReturn.isHittable)
        let search = app.buttons["Search Trains"]
        scrollTo(search, in: app)
        XCTAssertTrue(search.isHittable, "The compact reading order keeps Search reachable")
        XCTAssertFalse(element("journeySearchColumns", in: app).exists)
        capture(app, "debug-search-dark-AX5-action")
        goBack(in: app)
        XCTAssertTrue(app.homeAction("addJourneyFromTrips").isHittable)
    }

    @MainActor
    private func openSearch(appearance: String, largestText: Bool = false) -> XCUIApplication {
        if ProcessInfo.processInfo.environment["ROUNDHOUSE_TEST_ORIENTATION"] == "landscapeLeft" {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-JourneyPlanPreview", "-preference.appearance", appearance,
            "-preference.background", "white", "-preference.autoLockScreen", "NO",
            "-calendarSuggestions.v1.enabled", "NO", "-calendarSuggestions.v1.introductionDismissed", "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName",
            largestText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL",
        ]
        app.launch()
        let notice = app.alerts["Forwarded Tickets"]
        if notice.exists { notice.buttons["OK"].tap() }
        let search = app.homeAction("searchTrainsFromTrips", timeout: 10)
        XCTAssertTrue(search.isHittable)
        search.tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func placeButton(_ prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    private func dateValues(in app: XCUIApplication) -> [String] {
        // The compact native DatePicker exposes separate date/time buttons in a Form.
        app.buttons.allElementsBoundByIndex.map(\.label).filter {
            $0.range(of: #"\d.*(?:AM|PM)|[A-Za-z]{3} \d{1,2}, \d{4}"#, options: .regularExpression) != nil
        }.sorted()
    }

    @MainActor
    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication) {
        let candidates = app.scrollViews.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex
        let scroll = candidates.max { $0.frame.maxX < $1.frame.maxX }
        for _ in 0..<18 where !target.isHittable {
            if let scroll { scroll.swipeUp(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
    }

    @MainActor
    private func goBack(in app: XCUIApplication) {
        let sideBack = app.buttons["BackButton"]
        let back = sideBack.exists ? sideBack : app.navigationBars.buttons.firstMatch
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

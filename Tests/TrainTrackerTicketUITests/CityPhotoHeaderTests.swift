import XCTest

/// Standard-size regressions for the retained ink ticket and removal of the photo-credit UI.
@MainActor
final class CityPhotoHeaderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSettingsCoverageHasNoPhotoCredits() {
        let app = launch(["-AppStorePreview", "-AppStorePreviewSettings"])
        XCTAssertTrue(app.staticTexts["Settings"].firstMatch.waitForExistence(timeout: 10))
        let account = element("settingsAccountColumn", in: app)
        let scroll = viewport(in: account.exists ? account : app)
        let footer = app.staticTexts["Confirm critical travel information with the train operator."]
        reach(footer, in: scroll)
        XCTAssertTrue(footer.exists, "The coverage section is loaded before checking its rows")
        XCTAssertFalse(element("photoCredits", in: app).exists)
        XCTAssertFalse(app.buttons["Photo Credits"].exists)
        capture(app, "Settings coverage without Photo Credits")
    }

    func testSavedJourneyHeroKeepsPlainTicketWithoutPhotoGap() {
        let app = launch(["-MyTripsPastPlansQA", "-CityPhotoQAOffline"])
        let homeReady = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", ["firstRunPanelScroll", "addJourneyFromTrips", "moreFromTrips"]
        )).firstMatch
        XCTAssertTrue(homeReady.waitForExistence(timeout: 10))
        let history = app.buttons["pastJourneysFromHome"]
        app.expandJourneyPanel()
        let discovery = app.scrollViews["firstRunPanelScroll"]
        let home = discovery.exists ? discovery : viewport(in: app)
        reach(history, in: home)
        tap(history)
        let historyScroll = app.scrollViews["pastJourneysScroll"]
        XCTAssertTrue(historyScroll.waitForExistence(timeout: 5))
        let saved = app.buttons["pastJourney-77777777-7777-7777-7777-000000000003"]
        reach(saved, in: historyScroll)
        tap(saved)

        let hero = element("liveTripTicketHero", in: app)
        XCTAssertTrue(hero.waitForExistence(timeout: 5), "The selected saved leg uses the retained hero component")
        let side = element("journeyPlanSidePanel", in: app)
        let scroll = viewport(in: side.exists ? side : element("journeyPlanScroll", in: app))
        let service = hero.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Eurostar 9369")).firstMatch
        reach(service, in: scroll)
        XCTAssertLessThanOrEqual(service.frame.minY - hero.frame.minY, 36,
                                 "The ticket starts with its service, without the old photograph gap")
        XCTAssertTrue(hero.staticTexts["Bruxelles-Midi"].exists)
        XCTAssertTrue(hero.staticTexts["Amsterdam Centraal"].exists)
        XCTAssertFalse(hero.buttons["Station Map"].exists,
                       "A finished journey has no upcoming station to offer as a map action")
        capture(app, "Plain ink saved-journey ticket without a photograph gap")
    }

    private func launch(_ fixture: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = fixture + [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
            "-preference.appearance", "light", "-preference.background", "white",
            "-preference.autoLockScreen", "NO", "-calendarSuggestions.v1.enabled", "NO"
        ]
        app.launch()
        return app
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func viewport(in scope: XCUIElement) -> XCUIElement {
        if scope.elementType == .scrollView || scope.elementType == .collectionView { return scope }
        let candidates = scope.scrollViews.allElementsBoundByIndex + scope.collectionViews.allElementsBoundByIndex
        return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } ?? scope
    }

    private func reach(_ target: XCUIElement, in scroll: XCUIElement) {
        for _ in 0..<24 {
            let visible = scroll.frame.insetBy(dx: 6, dy: 10)
            if target.exists, visible.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)) { return }
            let up = !target.exists || target.frame.isEmpty || target.frame.midY >= visible.midY
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.76 : 0.24))
            start.press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.28 : 0.72)))
        }
        XCTFail("Cannot reach \(target.label) inside its scrolling content")
    }

    private func tap(_ target: XCUIElement) {
        XCTAssertTrue(target.exists && target.isEnabled)
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

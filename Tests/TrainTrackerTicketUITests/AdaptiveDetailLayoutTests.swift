import XCTest

/// Real fixture navigation and saved preferences; the caller owns orientation and Duo posture.
@MainActor
final class AdaptiveDetailLayoutTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testPlanLayoutKeepsItsTrainNavigationAndManagementReachable() {
        let app = Self.launch(["-JourneyPlanPreview", "-JourneyPlanPreviewDetail"])
        let side = Self.element("journeyPlanSidePanel", in: app)
        let compact = Self.element("journeyPlanScroll", in: app)
        Self.assertLayout(wide: side, compact: compact)
        let scroll = Self.viewport(in: side.exists ? side : compact)
        if side.exists {
            XCTAssertTrue(Self.element("journeyPlanMapCaption", in: app).waitForExistence(timeout: 5))
            let manage = Self.element("journeyPlanManageDisclosure", in: app)
            Self.reach(manage, in: scroll)
            Self.tap(manage, within: scroll)
            XCTAssertTrue(app.buttons["Stop Tracking Journey Trains"].waitForExistence(timeout: 5))
            Self.reach(manage, in: scroll)
            Self.tap(manage, within: scroll)
        } else {
            XCTAssertFalse(Self.element("journeyPlanMapCaption", in: app).exists)
        }
        let connection = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Eurostar 9369")).firstMatch
        Self.reach(connection, in: scroll)
        capture(app, "debug-plan-itinerary-light")
        Self.tap(connection, within: scroll)
        XCTAssertTrue(app.leadingTrain("eu:preview:eurostar-9369").waitForExistence(timeout: 10),
                      "A real itinerary leg opens that train's detail")
        Self.back(in: app)
        XCTAssertTrue((side.exists ? side : compact).waitForExistence(timeout: 5))
        Self.reach(connection, in: scroll)
        XCTAssertTrue(connection.exists, "Back preserves the saved itinerary")
        app.terminate()
    }

    @MainActor
    func testSettingsColumnsPreserveSavedPreferenceAndLowerNavigation() throws {
        let app = Self.launch(["-AppStorePreview", "-AppStorePreviewSettings"], appearance: "dark")
        let account = Self.element("settingsAccountColumn", in: app)
        let preferences = Self.element("settingsPreferencesColumn", in: app)
        Self.assertLayout(wide: preferences, compact: app.staticTexts["Settings"].firstMatch)
        if preferences.exists {
            XCTAssertTrue(account.exists)
            XCTAssertLessThanOrEqual(account.frame.maxX, preferences.frame.minX + 1)
            XCTAssertEqual(account.frame.minY, preferences.frame.minY, accuracy: 2)
        } else { XCTAssertFalse(account.exists) }
        let printed = Self.printedTickets(in: app)
        Self.reach(printed, in: Self.settingsViewport(in: app))
        let original = try XCTUnwrap(printed.value as? String)
        XCTAssertTrue(["0", "1"].contains(original))
        // A teardown also restores the preference after an assertion failure.
        addTeardownBlock {
            await MainActor.run {
                app.terminate()
                app.launch()
                let restored = Self.printedTickets(in: app)
                let scroll = Self.settingsViewport(in: app)
                Self.reach(restored, in: scroll)
                if restored.value as? String != original {
                    Self.tap(restored, within: scroll)
                    Self.assertValue(original, of: restored)
                }
                app.terminate()
            }
        }
        let changed = original == "1" ? "0" : "1"
        Self.tap(printed, within: Self.settingsViewport(in: app))
        Self.assertValue(changed, of: printed)
        app.terminate()
        app.launch() // No ticketTexture launch override: this reads the saved preference.
        let scroll = Self.settingsViewport(in: app)
        Self.reach(printed, in: scroll)
        Self.assertValue(changed, of: printed)
        let home = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Home Station")).firstMatch
        Self.reach(home, in: scroll)
        Self.tap(home, within: scroll)
        XCTAssertTrue(app.navigationBars["Home Station"].waitForExistence(timeout: 5))
        Self.tap(app.buttons["Cancel"].firstMatch)
        XCTAssertTrue(app.staticTexts["Settings"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["photoCredits"].exists)
        let sources = app.buttons["Data Sources & Attribution"]
        Self.reach(sources, in: Self.settingsViewport(in: app, account: true))
        Self.tap(sources, within: Self.settingsViewport(in: app, account: true))
        XCTAssertFalse(app.buttons["photoCredits"].exists, "Rail data attribution stays available without retired photo credits")
        capture(app, "debug-settings-dark-after-navigation")
    }

    @MainActor
    func testLargestTextUsesSingleColumnAndKeepsLowerControlsReachable() {
        let settings = Self.launch(["-AppStorePreview", "-AppStorePreviewSettings"], largestText: true)
        XCTAssertFalse(Self.element("settingsAccountColumn", in: settings).exists)
        XCTAssertFalse(Self.element("settingsPreferencesColumn", in: settings).exists)
        let home = settings.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Home Station")).firstMatch
        let form = Self.settingsViewport(in: settings)
        Self.reach(home, in: form)
        Self.tap(home, within: form)
        XCTAssertTrue(settings.navigationBars["Home Station"].waitForExistence(timeout: 5))
        Self.tap(settings.buttons["Cancel"].firstMatch)
        capture(settings, "debug-settings-AX5-single-column")
        settings.terminate()
        let plan = Self.launch(["-JourneyPlanPreview", "-JourneyPlanPreviewDetail"], largestText: true)
        let scroll = Self.element("journeyPlanScroll", in: plan)
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertFalse(Self.element("journeyPlanSidePanel", in: plan).exists)
        XCTAssertFalse(Self.element("journeyPlanMapCaption", in: plan).exists)
        let leg = plan.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Eurostar 9369")).firstMatch
        Self.reach(leg, in: Self.viewport(in: scroll))
        capture(plan, "debug-plan-AX5-single-column")
        Self.tap(leg, within: Self.viewport(in: scroll))
        let ticket = Self.element("journeyTicket-eu:preview:eurostar-9369", in: plan)
        XCTAssertTrue(ticket.waitForExistence(timeout: 3) || Self.element("liveTripTicketHero", in: plan).exists)
        XCTAssertFalse(scroll.exists, "The itinerary opens its train's accessible reading layout")
        Self.back(in: plan)
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        plan.terminate()
    }

    @MainActor
    private static func launch(_ fixture: [String], appearance: String = "light", largestText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = fixture + ["-preference.appearance", appearance, "-preference.background", "white",
            "-preference.autoLockScreen", "NO", "-calendarSuggestions.v1.enabled", "NO",
            "-calendarSuggestions.v1.introductionDismissed", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", largestText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        let notice = app.alerts["Forwarded Tickets"]
        if notice.exists { notice.buttons["OK"].tap() }
        if fixture.contains("-AppStorePreviewSettings") {
            XCTAssertTrue(app.staticTexts["Settings"].firstMatch.waitForExistence(timeout: 10))
        } else {
            XCTAssertTrue(Self.element("journeyPlanSidePanel", in: app).waitForExistence(timeout: 2)
                          || Self.element("journeyPlanScroll", in: app).waitForExistence(timeout: 8))
        }
        return app
    }

    @MainActor
    private static func assertLayout(wide: XCUIElement, compact: XCUIElement) {
        let env = ProcessInfo.processInfo.environment
        let expected = env["ROUNDHOUSE_EXPECT_WIDE_UI"] ?? env["TEST_RUNNER_ROUNDHOUSE_EXPECT_WIDE_UI"]
        if expected == "1" { XCTAssertTrue(wide.waitForExistence(timeout: 5)) }
        else if expected == "0" { XCTAssertTrue(compact.waitForExistence(timeout: 5)); XCTAssertFalse(wide.exists) }
        else { XCTAssertTrue(wide.waitForExistence(timeout: 1) || compact.exists) }
    }

    @MainActor private static func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    @MainActor private static func printedTickets(in app: XCUIApplication) -> XCUIElement {
        app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Printed Tickets")).firstMatch
    }
    @MainActor private static func settingsViewport(in app: XCUIApplication, account: Bool = false) -> XCUIElement {
        let column = Self.element(account ? "settingsAccountColumn" : "settingsPreferencesColumn", in: app)
        return Self.viewport(in: column.waitForExistence(timeout: 1) ? column : app)
    }
    @MainActor private static func viewport(in scope: XCUIElement) -> XCUIElement {
        if scope.elementType == .scrollView || scope.elementType == .collectionView { return scope }
        let candidates = scope.scrollViews.allElementsBoundByIndex + scope.collectionViews.allElementsBoundByIndex
        return candidates.max { $0.frame.maxX < $1.frame.maxX } ?? scope
    }
    @MainActor private static func reach(_ target: XCUIElement, in scroll: XCUIElement) {
        for _ in 0..<32 {
            let visible = scroll.frame.insetBy(dx: 4, dy: 10)
            if target.exists, visible.contains(target.frame) { return }
            let up = !target.exists || target.frame.isEmpty || target.frame.midY >= visible.midY
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.76 : 0.24))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.28 : 0.72)))
        }
        XCTFail("Cannot reach \(target.label) inside its actual scroll viewport")
    }
    @MainActor private static func tap(_ target: XCUIElement, within viewport: XCUIElement? = nil) {
        XCTAssertTrue(target.waitForExistence(timeout: 5) && target.isEnabled)
        if let viewport { XCTAssertTrue(viewport.frame.contains(target.frame)) }
        if target.elementType == .switch, target.switches.firstMatch.exists {
            target.switches.firstMatch.tap()
        } else if target.isHittable { target.tap() }
        else { target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    }
    @MainActor private static func assertValue(_ value: String, of target: XCUIElement) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 5), .completed)
    }
    @MainActor private static func back(in app: XCUIApplication) {
        let custom = app.buttons["BackButton"]
        Self.tap(custom.exists ? custom : app.navigationBars.buttons.firstMatch)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import XCTest
import UIKit

/// Whole-app interaction checks on the isolated `-FrictionlessIntakeQA` fixture: signed out, a
/// temporary ticket vault, in-memory journeys and a deterministic local search client. Synthetic
/// image/PDF payloads exercise OCR and parsing without depending on a simulator Photos/Files library;
/// separate checks cover opening and dismissing each system picker.
final class QualityAuditFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Launch

    @MainActor
    func testSignedOutLaunchShowsNoUnrequestedAlertOrSheet() {
        let app = launch()
        capture(app, "Launch signed out")
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 4), "No alert should appear before the person acts")
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertTrue(app.buttons["addJourneyFromTrips"].isHittable, "Add Journey is reachable on first launch")
    }

    // MARK: - System pickers

    @MainActor
    func testImportDisclosureAtLargestAccessibilitySize() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openAddJourney(app)
        let explanation = app.staticTexts["addJourneyImportExplanation"]
        scrollUntilHittable(explanation, in: app)
        XCTAssertTrue(explanation.isHittable, "Import disclosure remains readable")
        XCTAssertTrue(explanation.label.contains("find matching trains automatically"))
        XCTAssertTrue(explanation.label.contains("original ticket stays on this device"))
        XCTAssertGreaterThanOrEqual(explanation.frame.minX, app.frame.minX - 1)
        XCTAssertLessThanOrEqual(explanation.frame.maxX, app.frame.maxX + 1)
        capture(app, "Import disclosure at AX5", screen: true)
    }

    @MainActor
    func testQAImageFixtureImportReachesSingleTrackConfirmation() {
        let app = launch(extra: ["-FrictionlessIntakeQADocumentFixtures"])
        openAddJourney(app)
        app.buttons["addJourneyQAImageFixture"].tap()
        let track = app.buttons["trackResolvedJourney"]
        XCTAssertTrue(track.waitForExistence(timeout: 25), "On-device OCR, match and review complete from a ticket image")
        capture(app, "Photo import review")
        XCTAssertFalse(app.buttons["checkJourneyTickets"].exists, "An imported ticket is not sent back to ticket purchase")
    }

    @MainActor
    func testPhotoPickerOpensAndCanBeDismissed() {
        let app = launch()
        openAddJourney(app)
        app.buttons["addJourneyPhoto"].tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(app.buttons["addJourneyPhoto"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testQAPDFFixtureImportReachesSingleTrackConfirmation() {
        let app = launch(extra: ["-FrictionlessIntakeQADocumentFixtures"])
        openAddJourney(app)
        app.buttons["addJourneyQAPDFFixture"].tap()
        let track = app.buttons["trackResolvedJourney"]
        XCTAssertTrue(track.waitForExistence(timeout: 25), "PDF text extraction, match and review complete from a PDF ticket")
        capture(app, "PDF import review")
    }

    @MainActor
    func testDocumentPickerOpensAndCanBeDismissed() {
        let app = launch()
        openAddJourney(app)
        app.buttons["addJourneyFile"].tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(app.buttons["addJourneyFile"].waitForExistence(timeout: 5))
    }

    // MARK: - Presentation robustness

    @MainActor
    func testRepeatedTapsAndInterruptedSheetsNeverStick() {
        let app = launch()
        let add = app.homeAction("addJourneyFromTrips")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.doubleTap()
        let paste = app.buttons["addJourneyPaste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "A double tap presents Add Journey once")

        // Interrupt the paste sheet with a swipe, then reopen it.
        paste.tap()
        XCTAssertTrue(app.textViews["addJourneyPasteText"].waitForExistence(timeout: 5))
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "Swipe-dismissing Paste returns to Add Journey")
        paste.tap()
        XCTAssertTrue(app.textViews["addJourneyPasteText"].waitForExistence(timeout: 5), "Paste can be reopened")
        app.buttons["Cancel"].tap()

        // Close Add Journey, reopen immediately, and open Calendar import then cancel it.
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "Add Journey reopens after closing")
        app.buttons["Import from Calendar"].tap()
        let calendarClose = app.navigationBars["Import from Calendar"].buttons["Close"]
        XCTAssertTrue(calendarClose.waitForExistence(timeout: 8))
        capture(app, "Calendar import from Add Journey")
        calendarClose.tap()
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "Closing Calendar returns to Add Journey")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    @MainActor
    func testSearchFailureOffersRetryAndKeepsTicketDetails() {
        let app = launch(extra: ["-FrictionlessIntakeQAFailSearch"])
        paste(app, completeTicket())
        let retry = app.buttons["smartReviewRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20), "A failed search explains itself and offers retry")
        capture(app, "Search failure with retry")
        retry.tap()
        let track = app.buttons["trackResolvedJourney"]
        XCTAssertTrue(track.waitForExistence(timeout: 20), "Retry reaches review without retyping")
    }

    @MainActor
    func testUnnumberedTicketMatchesExactDepartureThenEditsDetailsWithKeyboard() {
        let app = launch()
        paste(app, """
        Amtrak
        Boston South Station to New York Penn Station
        Departs \(futureDay()) 8:30 AM
        """)
        // Without a train number, only an exact departure between the stations is selected.
        let track = app.buttons["trackResolvedJourney"]
        XCTAssertTrue(track.waitForExistence(timeout: 20))
        XCTAssertTrue(app.navigationBars["Review Journey"].exists, "One title for the whole review")
        capture(app, "Unnumbered ticket exact match")
        let edit = app.buttons["smartReviewEditDetails"]
        XCTAssertTrue(edit.exists)
        edit.tap()
        let origin = app.textFields["smartReviewOrigin"]
        XCTAssertTrue(origin.waitForExistence(timeout: 5), "Edit Details shows every field")
        origin.tap()
        capture(app, "Editing details with keyboard")
        let find = app.buttons["smartReviewFindTrain"]
        scrollUntilHittable(find, in: app)
        XCTAssertTrue(find.isHittable, "Find Train stays reachable while the keyboard is up")
        find.tap()
        XCTAssertTrue(track.waitForExistence(timeout: 20), "Searching again after editing reaches review")
    }

    @MainActor
    func testTrackOpenTicketAndReopenReviewAfterClose() {
        let app = launch()
        paste(app, completeTicket())
        let track = app.buttons["trackResolvedJourney"]
        XCTAssertTrue(track.waitForExistence(timeout: 20))
        scrollUntilHittable(track, in: app)
        track.tap()
        let showTicket = app.buttons["homeShowTicket"]
        XCTAssertTrue(showTicket.waitForExistence(timeout: 10))
        capture(app, "Home after tracking")
        scrollUntilHittable(showTicket, in: app)
        showTicket.tap()
        XCTAssertTrue(app.navigationBars["Ticket"].waitForExistence(timeout: 5))
        capture(app, "Saved ticket offline copy")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(showTicket.isHittable, "My Trips remains available beside the ticket")
            let openJourney = app.buttons["homeOpenJourney"]
            XCTAssertTrue(openJourney.isHittable)
            openJourney.tap()
            XCTAssertTrue(app.navigationBars["Journey"].waitForExistence(timeout: 5))
            showTicket.tap()
            XCTAssertTrue(app.navigationBars["Ticket"].waitForExistence(timeout: 5), "The saved ticket can be reopened from the sidebar")
            capture(app, "Saved ticket reopened from sidebar")
        } else {
            app.navigationBars["Ticket"].buttons.firstMatch.tap()
            XCTAssertTrue(showTicket.waitForExistence(timeout: 5), "Back returns to My Trips")
        }
    }

    // MARK: - Settings, search and map

    @MainActor
    func testIPadDefaultsToCurrentSavedJourneyBeforeStandaloneFutureTrain() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad split view") }
        let app = XCUIApplication()
        app.launchArguments = ["-JourneyPlanPreview"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'defaultJourneyDetail-'")).firstMatch.waitForExistence(timeout: 10))
        capture(app, "iPad opens current saved journey by default")
    }

    @MainActor
    func testUndatedTicketKeepsTravelDatePickerAfterSettingDate() {
        let app = launch()
        paste(app, "Amtrak Acela 2150\nBoston South Station to New York Penn Station")
        let setDate = app.buttons["smartReviewSetDate"]
        XCTAssertTrue(setDate.waitForExistence(timeout: 10))
        setDate.tap()
        let date = app.datePickers["smartReviewDate"]
        XCTAssertTrue(date.waitForExistence(timeout: 5), "Setting the initial date must leave a picker to choose the ticket's actual date")
        date.tap()
        capture(app, "Undated ticket travel date remains editable")
    }

    @MainActor
    func testStoppingJourneyTrackingKeepsOriginalTicketForReview() {
        let app = launch()
        paste(app, completeTicket())
        let track = app.buttons["trackResolvedJourney"]
        XCTAssertTrue(track.waitForExistence(timeout: 20))
        scrollUntilHittable(track, in: app)
        track.tap()
        let open = app.buttons["homeOpenJourney"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        app.buttons["journeyIntakeUndoDismiss"].tap()
        scrollUntilHittable(open, in: app)
        open.tap()
        let stop = app.buttons["Stop Tracking Journey Trains"]
        scrollUntilHittable(stop, in: app)
        XCTAssertTrue(stop.isHittable)
        stop.tap()
        let confirm = app.buttons["Stop Tracking 1 Train"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        scrollUntilHittable(confirm, in: app)
        capture(app, "Review stopping only this journey's train")
        confirm.tap()
        XCTAssertTrue(app.buttons["resumeImport"].waitForExistence(timeout: 10), "Removing tracking preserves the original ticket")
        app.buttons["resumeImport"].tap()
        XCTAssertTrue(track.waitForExistence(timeout: 20), "The preserved ticket can be reviewed again")
    }

    @MainActor
    func testMissingStationsKeepKeyboardFocusAndRecognizedSelectionsAfterRelaunch() {
        let app = launch()
        paste(app, "Amtrak Acela 2150\nTravel date: \(futureDay())\nDeparts 8:05 AM")
        let origin = app.textFields["smartReviewOrigin"]
        XCTAssertTrue(origin.waitForExistence(timeout: 10))
        origin.tap()
        origin.typeText("B")
        XCTAssertEqual(origin.value as? String, "B", "The first letter keeps the field and its focus")
        origin.typeText("os")
        XCTAssertEqual(origin.value as? String, "Bos", "Typing continues without tapping the field again")
        let originSuggestion = app.buttons["smartReviewStationSuggestion-origin-qa:boston-south"]
        XCTAssertTrue(originSuggestion.waitForExistence(timeout: 10))
        capture(app, "Manual station suggestions after continuous typing")
        scrollUntilHittable(originSuggestion, in: app)
        XCTAssertTrue(originSuggestion.isHittable)
        originSuggestion.tap()
        XCTAssertEqual(origin.value as? String, "Boston South Station")

        let destination = app.textFields["smartReviewDestination"]
        destination.tap()
        destination.typeText("New")
        let destinationSuggestion = app.buttons["smartReviewStationSuggestion-destination-qa:new-york-penn"]
        XCTAssertTrue(destinationSuggestion.waitForExistence(timeout: 10))
        scrollUntilHittable(destinationSuggestion, in: app)
        XCTAssertTrue(destinationSuggestion.isHittable)
        capture(app, "Arrival suggestion reachable above keyboard")
        destinationSuggestion.tap()
        XCTAssertEqual(destination.value as? String, "New York Penn Station")
        app.navigationBars["Review Journey"].buttons["Close"].tap()
        app.terminate()

        app.launchArguments = ["-FrictionlessIntakeQA", "-WorkflowQANoAnimations"]
        app.launch()
        let resume = app.buttons["resumeImport"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()
        XCTAssertTrue(app.buttons["trackResolvedJourney"].waitForExistence(timeout: 20),
                      "Recognized stations and the printed departure survive reopening")
        capture(app, "Recognized station draft resumed to confirmation")
    }

    @MainActor
    func testSettingsSignInCanBeOpenedCancelledAndReopened() {
        let app = launch()
        tab(app, "Settings")
        capture(app, "Settings signed out")
        let signIn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sign In' OR label BEGINSWITH 'Sign in'")).firstMatch
        scrollUntilHittable(signIn, in: app)
        XCTAssertTrue(signIn.waitForExistence(timeout: 5), "Settings offers sign in while signed out")
        signIn.tap()
        XCTAssertTrue(app.staticTexts["Sign in to stay connected"].waitForExistence(timeout: 5))
        capture(app, "Sign in sheet")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.tap()
        XCTAssertTrue(app.staticTexts["Sign in to stay connected"].waitForExistence(timeout: 5), "Sign in reopens")
    }

    @MainActor
    func testEveryTabRendersWithoutOverlap() {
        let app = launch()
        // No tab bar: each screen opens from My Trips and returns to it.
        for screen in ["Search", "Settings", "My Trips"] {
            self.tab(app, screen)
            sleep(1)
            capture(app, "Screen \(screen)")
            XCTAssertFalse(app.alerts.firstMatch.exists, "Opening \(screen) raises no alert")
        }
    }

    @MainActor
    func testLandscapeKeepsAddJourneyAndTrackConfirmationReachable() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch()
        sleep(2)
        capture(app, "Landscape My Trips")
        paste(app, completeTicket())
        let track = app.buttons["trackResolvedJourney"]
        XCTAssertTrue(track.waitForExistence(timeout: 20))
        scrollUntilHittable(track, in: app)
        XCTAssertTrue(track.isHittable, "Track Journey is reachable in landscape")
        capture(app, "Landscape review")
    }

    // MARK: - Helpers

    @MainActor
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FrictionlessIntakeQA", "-FrictionlessIntakeQAReset", "-WorkflowQANoAnimations"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func openAddJourney(_ app: XCUIApplication) {
        let add = app.homeAction("addJourneyFromTrips")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(app.buttons["addJourneyPhoto"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func paste(_ app: XCUIApplication, _ text: String) {
        openAddJourney(app)
        app.buttons["addJourneyPaste"].tap()
        let editor = app.textViews["addJourneyPasteText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(text)
        app.buttons["addJourneyPasteContinue"].tap()
    }

    private func completeTicket() -> String {
        """
        Amtrak Acela 2150
        Boston South Station to New York Penn Station
        Departs \(futureDay()) 8:05 AM
        Coach 5 Seat 14A
        """
    }

    private func futureDay() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: Calendar.current.date(byAdding: .day, value: 7, to: .now)!)
    }

    /// There is no tab bar. My Trips is the root; Search and Settings open from its buttons.
    @MainActor
    private func tab(_ app: XCUIApplication, _ title: String) {
        for _ in 0..<4 where !app.isShowingHome {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { break }
            back.tap()
        }
        switch title {
        case "Search": app.homeAction("searchTrainsFromTrips").tap()
        case "Settings": app.homeAction("settingsFromTrips").tap()
        default: break
        }
    }

    @MainActor
    private func tapScreen(_ app: XCUIApplication, _ x: CGFloat, _ y: CGFloat) {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
    }

    @MainActor
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable {
            app.swipeUp()
        }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String, screen: Bool = false) {
        let shot = screen ? XCUIScreen.main.screenshot() : app.screenshot()
        add(named(XCTAttachment(screenshot: shot), name))
    }

    private func named(_ attachment: XCTAttachment, _ name: String) -> XCTAttachment {
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}

/// Deterministic regression checks on the real phone/iPad My Trips navigation roots.
final class MyTripsTimeBucketUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testTimeSectionsRemainReachableAndTrainOpens() {
        checkTimeSections()
    }

    @MainActor
    func testTimeSectionsAtLargestAccessibilitySize() {
        checkTimeSections(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }

    @MainActor
    func testTimeSectionsInLandscape() {
        checkTimeSections(landscape: true)
    }

    @MainActor
    private func checkTimeSections(extra: [String] = [], landscape: Bool = false) {
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-MyTripsTimeBucketsQA"] + extra
        app.launch()
        revealSidebarIfNeeded(app)
        let currentTrain = app.leadingTrain("eu:preview:time-bucket-9401")
        XCTAssertTrue(currentTrain.waitForExistence(timeout: 10))
        XCTAssertTrue(currentTrain.label.contains("next stop: Bruxelles-Midi"), currentTrain.label)
        XCTAssertFalse(currentTrain.label.contains("next stop: Paris Nord"), currentTrain.label)
        XCTAssertTrue(currentTrain.label.contains("Platform 4"), currentTrain.label)
        assertWithinScreen(currentTrain, in: app)
        capture(app, "My Trips current and upcoming")
        app.expandJourneyPanel()
        // On iPhone the lists scroll inside the journey panel; the header's rail scrolls too.
        let panel = app.scrollViews["journeyDrawerScroll"]
        let sidePanel = app.scrollViews["journeySidePanel"]
        let sidebar = panel.exists ? panel : (sidePanel.exists ? sidePanel : app.scrollViews.firstMatch)
        for heading in ["Current Trains", "Upcoming Trains", "Other Trains"] {
            let label = app.staticTexts[heading]
            scrollTo(label, in: sidebar)
            XCTAssertTrue(label.isHittable, "\(heading) remains reachable")
            capture(app, "My Trips \(heading)")
        }
        let pastTrain = app.buttons["individualTrain-eu:preview:time-bucket-9302"]
        XCTAssertFalse(pastTrain.exists, "Completed trains stay behind the history button")
        let history = app.buttons["pastJourneysFromHome"]
        scrollTo(history, in: sidebar)
        XCTAssertTrue(history.isHittable)
        history.tap()
        XCTAssertTrue(app.navigationBars["Past Journeys"].waitForExistence(timeout: 5))
        let historyScroll = app.scrollViews["pastJourneysScroll"]
        XCTAssertTrue(historyScroll.waitForExistence(timeout: 5))
        scrollTo(pastTrain, in: historyScroll)
        XCTAssertTrue(pastTrain.isHittable)
        assertWithinScreen(pastTrain, in: app)
        pastTrain.tap()
        XCTAssertTrue(app.staticTexts["Eurostar 9302"].firstMatch.waitForExistence(timeout: 10))
        assertWithinScreen(app.journeyTicket(), in: app)
        capture(app, "Past train detail")
    }

    @MainActor
    func testNearestFutureTrainIsDefaultDespiteReverseSaveOrder() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-MyTripsTimeBucketsQA", "-MyTripsUpcomingOnlyQA"]
        app.launch()
        // iPad portrait opens the default detail; iPhone opens the highlighted list ticket.
        if UIDevice.current.userInterfaceIdiom == .pad {
            let detail = app.descendants(matching: .any).matching(identifier: "defaultTripDetail-eu:preview:time-bucket-9501").firstMatch
            XCTAssertTrue(detail.waitForExistence(timeout: 10), "iPad opens the nearest train before any selection")
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "defaultTripDetail-eu:preview:time-bucket-9502").firstMatch.exists)
            capture(app, "iPad nearest future default detail")
        }
        if app.buttons["Show Sidebar"].waitForExistence(timeout: 3) {
            XCTAssertTrue(app.staticTexts["Eurostar 9501"].firstMatch.exists)
            capture(app, "iPad nearest future default detail")
            app.buttons["Show Sidebar"].tap()
        }
        XCTAssertTrue(app.leadingTrain("eu:preview:time-bucket-9501").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["highlightedTrain-eu:preview:time-bucket-9502"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "journeyTicket-eu:preview:time-bucket-9502").firstMatch.exists)
        capture(app, "Nearest future train highlighted")
    }

    @MainActor
    private func revealSidebarIfNeeded(_ app: XCUIApplication) {
        if app.buttons["Show Sidebar"].waitForExistence(timeout: 3) {
            app.buttons["Show Sidebar"].tap()
        }
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in scrollView: XCUIElement) {
        // Short drags avoid skipping a ticket in the phone's shallow landscape viewport.
        for _ in 0..<30 where !element.isHittable {
            let aboveViewport = element.exists && element.frame.maxY < scrollView.frame.minY + 40
            let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: aboveViewport ? 0.4 : 0.7))
            let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: aboveViewport ? 0.7 : 0.4))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    @MainActor
    private func assertWithinScreen(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX - 1)
        XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX + 1, "Ticket must fit without horizontal overflow")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

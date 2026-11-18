import XCTest

/// Native interaction checks for Add Journey using the isolated `-FrictionlessIntakeQA` fixture:
/// a temporary ticket vault, in-memory journeys and a deterministic local search client.
final class FrictionlessJourneyFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testCompleteTicketNeedsOneTrackConfirmationAndUndoRemovesOnlyTheAddition() {
        let app = launch(reset: true)
        pasteTicket(app, text: completeTicket())

        let track = app.buttons["trackResolvedJourney"]
        XCTAssertTrue(track.waitForExistence(timeout: 20), "A unique match opens Track Journey without retyping")
        scrollUntilHittable(track, in: app)
        capture(app, name: "Smart review single confirmation")
        track.tap()

        XCTAssertTrue(app.staticTexts["journeyIntakeUndoMessage"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["journeyHomeFocus"].waitForExistence(timeout: 5)
            || app.staticTexts["Your next journey"].waitForExistence(timeout: 5))
        capture(app, name: "My Trips after tracking with Undo")

        let showTicket = app.buttons["homeShowTicket"]
        XCTAssertTrue(showTicket.waitForExistence(timeout: 5), "The ticket is one tap from the journey")
        app.buttons["journeyIntakeUndo"].tap()
        XCTAssertFalse(showTicket.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["resumeImport"].waitForExistence(timeout: 5), "The original ticket is kept for another try")
        capture(app, name: "After Undo ticket kept in Unfinished")
    }

    @MainActor
    func testRepeatImportOpensSavedJourneyWithoutDuplicate() {
        let app = launch(reset: true)
        pasteTicket(app, text: completeTicket())
        let track = app.buttons["trackResolvedJourney"]
        XCTAssertTrue(track.waitForExistence(timeout: 20))
        scrollUntilHittable(track, in: app)
        track.tap()
        XCTAssertTrue(app.staticTexts["journeyIntakeUndoMessage"].waitForExistence(timeout: 10))

        pasteTicket(app, text: completeTicket())
        XCTAssertTrue(app.navigationBars["Journey"].waitForExistence(timeout: 10), "Identical ticket opens the saved journey")
        capture(app, name: "Repeat import opens saved journey")
        XCTAssertTrue(app.buttons["journeyShowTicket"].waitForExistence(timeout: 5) || scrollToFind(app.buttons["journeyShowTicket"], in: app))
    }

    @MainActor
    func testIncompleteTicketAsksOnlyForMissingTimeAndResumesAfterRelaunch() {
        let app = launch(reset: true)
        pasteTicket(app, text: """
        Amtrak Acela 2150
        Boston South Station to New York Penn Station
        Travel date: \(futureDay())
        """)

        let setTime = app.buttons["smartReviewSetTime"]
        XCTAssertTrue(setTime.waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["smartReviewOrigin"].exists, "Known stations are not asked for again")
        capture(app, name: "Only missing departure time requested")
        setTime.tap()
        XCTAssertTrue(app.switches["smartReviewTimeChecked"].waitForExistence(timeout: 5))
        let findTrain = app.buttons["smartReviewFindTrain"]
        XCTAssertTrue(findTrain.waitForExistence(timeout: 5), "The search action exists before its disabled state is checked")
        scrollUntilHittable(findTrain, in: app)
        XCTAssertFalse(findTrain.isEnabled, "An unprinted time must be checked explicitly")
        app.navigationBars.buttons["Close"].tap()

        let resume = app.buttons["resumeImport"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        app.terminate()

        let relaunched = launch(reset: false)
        let resumed = relaunched.buttons["resumeImport"]
        XCTAssertTrue(resumed.waitForExistence(timeout: 10), "Unfinished work survives restart")
        capture(relaunched, name: "Unfinished import after relaunch")
        resumed.tap()
        XCTAssertTrue(relaunched.switches["smartReviewTimeChecked"].waitForExistence(timeout: 10), "The entered time was restored")
        capture(relaunched, name: "Resumed review keeps entered time")
    }

    @MainActor
    func testAccessibilitySizeReachesAddJourneyAndTrackConfirmation() {
        let app = launch(reset: true, accessibilitySize: true)
        let add = app.homeAction("addJourneyFromTrips")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(add.isHittable)
        capture(app, name: "AX My Trips Add Journey")
        pasteTicket(app, text: completeTicket())
        let track = app.buttons["trackResolvedJourney"]
        XCTAssertTrue(track.waitForExistence(timeout: 20))
        scrollUntilHittable(track, in: app)
        XCTAssertTrue(track.isHittable)
        capture(app, name: "AX Track Journey reachable")
        track.tap()
        let showTicket = app.buttons["homeShowTicket"]
        XCTAssertTrue(showTicket.waitForExistence(timeout: 10))
        capture(app, name: "AX contextual home")
        app.buttons["journeyIntakeUndoDismiss"].tap()
        scrollUntilHittable(showTicket, in: app)
        XCTAssertTrue(showTicket.isHittable)
        // There is no tab bar to lift the action above any more; a swipe here would move the
        // journey panel out from under the tap.
        capture(app, name: "AX home ticket action")
        showTicket.tap()
        XCTAssertTrue(app.navigationBars["Ticket"].waitForExistence(timeout: 5))
        capture(app, name: "AX local ticket detail")
    }

    // MARK: - Helpers

    @MainActor
    private func launch(reset: Bool, accessibilitySize: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FrictionlessIntakeQA"] + (reset ? ["-FrictionlessIntakeQAReset"] : [])
        if accessibilitySize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        // Preview accounts can surface an unrelated forwarding sign-in alert on launch.
        let alert = app.alerts["Forwarded Tickets"]
        if alert.waitForExistence(timeout: 3) { alert.buttons["OK"].tap() }
        return app
    }

    @MainActor
    private func pasteTicket(_ app: XCUIApplication, text: String) {
        let add = app.homeAction("addJourneyFromTrips")
        if !add.waitForExistence(timeout: 10) {
            // My Trips is the root; step back to it from whichever screen is open.
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
        }
        scrollUntilHittable(add, in: app, upward: true)
        add.tap()
        let paste = app.buttons["addJourneyPaste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        capture(app, name: "Add Journey sources")
        paste.tap()
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

    @MainActor
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = false) {
        for _ in 0..<10 where !element.isHittable {
            upward ? app.swipeDown() : app.swipeUp()
        }
    }

    @MainActor
    private func scrollToFind(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<8 {
            if element.exists { return true }
            app.swipeUp()
        }
        return element.exists
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

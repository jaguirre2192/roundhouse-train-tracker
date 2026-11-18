import XCTest

/// The My Trips Calendar suggestions invitation. Only the paths that never request Calendar
/// permission run here; permission and event reading are covered by unit and EventKit tests.
final class CalendarSuggestionsCardTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testNotNowHidesTheInvitationWithoutReadingCalendarAndSurvivesRelaunch() {
        let app = XCUIApplication()
        // Argument-domain defaults reset the saved preferences for this launch only.
        app.launchArguments = [
            "-AppStorePreview",
            "-calendarSuggestions.v1.introductionDismissed", "NO",
            "-calendarSuggestions.v1.enabled", "NO",
        ]
        app.launch()
        setReviewOrientation()

        let notNow = app.buttons["calendar-suggestions-not-now"]
        app.scrollJourneyContent(to: notNow)
        XCTAssertTrue(notNow.waitForExistence(timeout: 10), "The invitation shows until the person decides")
        XCTAssertTrue(app.buttons["calendar-suggestions-enable"].exists)
        requestNativeCapture(role: "free-calendar")
        notNow.tap()
        XCTAssertFalse(notNow.waitForExistence(timeout: 2), "Not Now hides the invitation immediately")
        XCTAssertFalse(app.alerts.firstMatch.exists, "No permission prompt without Turn On")

        app.terminate()
        app.launchArguments = ["-AppStorePreview"]
        app.launch()
        XCTAssertTrue(app.buttons["moreFromTrips"].waitForExistence(timeout: 10) || app.isShowingHome)
        app.scrollJourneyContentToEnd()
        XCTAssertFalse(app.buttons["calendar-suggestions-not-now"].exists, "Not Now is remembered across launches")
    }
}

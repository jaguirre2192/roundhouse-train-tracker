import XCTest

/// Calendar invitation and review UI. EventKit permissions and real reads have separate integration tests.
final class CalendarSuggestionsCardTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testAllDayCalendarReviewRequiresChoosingAnExplicitDepartureTime() {
        let app = XCUIApplication()
        app.launchArguments = ["-CalendarImportPreview"]
        app.launch()
        setReviewOrientation()

        let allDay = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "9032")).firstMatch
        reveal(allDay, in: app)
        XCTAssertTrue(allDay.waitForExistence(timeout: 8))
        allDay.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        let find = app.buttons["Find Trains"]
        XCTAssertTrue(find.waitForExistence(timeout: 8))
        XCTAssertFalse(find.isEnabled)
        let setTime = app.buttons["calendarDepartureTime"]
        reveal(setTime, in: app)
        XCTAssertTrue(setTime.isHittable)
        setTime.tap()
        let apply = app.buttons["calendarApplyDepartureTime"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        // The date-only fixture offers noon as a starting point. The action must name the
        // same time as the wheel, including when the popover is opened for the first time.
        let expected = Date(timeIntervalSince1970: 43_200)
        var format = Date.FormatStyle(date: .omitted, time: .shortened)
        format.timeZone = .gmt
        XCTAssertEqual(apply.label, "Use \(expected.formatted(format))")
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "15")
        let chosenTime = expected.addingTimeInterval(15 * 60).formatted(format)
        XCTAssertEqual(apply.label, "Use \(chosenTime)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Choose Calendar departure time"
        attachment.lifetime = .keepAlways
        add(attachment)
        apply.tap()
        XCTAssertTrue(find.isEnabled)
        XCTAssertTrue(setTime.label.contains(chosenTime))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        let surface = list.exists ? list : app.windows.firstMatch
        // Drag inside the form, to one side of the Duo's unfolded center crease.
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.8))
            let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.32))
            start.press(forDuration: 0.08, thenDragTo: end)
        }
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

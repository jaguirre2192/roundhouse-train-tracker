import XCTest

@MainActor
final class RiderConvenienceFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAutomaticLiveActivitiesCanBeChangedInSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppStorePreview", "-AppStorePreviewSettings"]
        app.launch()
        setReviewOrientation()
        let row = app.switches.matching(identifier: "settings.autoLiveActivity").firstMatch
        let column = app.descendants(matching: .any).matching(identifier: "settingsPreferencesColumn").firstMatch
        scrollTo(row, in: column.exists ? column : app)
        let control = row.switches.firstMatch.exists ? row.switches.firstMatch : row
        let previous = try XCTUnwrap(control.value as? String)
        control.tap()
        XCTAssertEqual(control.value as? String, previous == "0" ? "1" : "0")
        requestNativeCapture(role: "free-activities")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Automatic Live Activities setting"
        attachment.lifetime = .keepAlways
        add(attachment)
        control.tap()
        XCTAssertEqual(control.value as? String, previous)
    }

    func testForwardingLeadsStraightToTheAccountOnAFreeGuestInstall() {
        let app = XCUIApplication()
        app.launchArguments = ["-FrictionlessIntakeQA", "-FrictionlessIntakeQAReset", "-WorkflowQANoAnimations"]
        app.launch()
        setReviewOrientation()
        let addJourney = app.homeAction("addJourneyFromTrips")
        XCTAssertTrue(addJourney.waitForExistence(timeout: 10))
        addJourney.tap()
        let link = app.buttons["Forward a Booking Email"]
        scrollTo(link, in: app)
        link.tap()
        let signIn = app.buttons["Sign In or Create Account"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 6))
        requestNativeCapture(role: "free-forwarding")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Forward a booking email"
        attachment.lifetime = .keepAlways
        add(attachment)
        signIn.tap()
        XCTAssertTrue(app.buttons["Continue with Google"].waitForExistence(timeout: 6))
        app.buttons["Continue as Guest"].tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 6))
    }

    private func scrollTo(_ element: XCUIElement, in viewport: XCUIElement) {
        for _ in 0..<10 {
            if element.exists && element.isHittable {
                let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
                if viewport.frame.contains(center) { return }
            }
            viewport.swipeUp()
        }
        XCTFail("Could not reach the requested control in its scroll area.")
    }
}

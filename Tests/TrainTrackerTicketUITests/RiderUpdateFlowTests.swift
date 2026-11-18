import CoreLocation
import XCTest

final class RiderUpdateFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor func testAmtrakLosesPositionWhileArrivalEstimatesAndTrackHistoryRemain() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AmtrakSignalGapQA"]
        app.launch()
        let outage = updates(in: app, containing: "Last position reported")
        XCTAssertTrue(outage.waitForExistence(timeout: 15))
        if !outage.isHittable { app.scrollJourneyContent(to: outage) }
        XCTAssertTrue(outage.label.contains("Estimated arrival at New York Penn"), outage.label)
        requestNativeCapture(role: "amtrak-signal")
        capture(app, "Amtrak position gap with independent arrival estimate")
        outage.tap()
        XCTAssertTrue(app.navigationBars["Recent Updates"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Track changed from 4 to 7")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Arrival estimated 12 min late")).firstMatch.exists)
        requestNativeCapture(role: "train-changes")
        capture(app, "Amtrak recent changes")
        app.buttons["Done"].tap()
        XCTAssertTrue(outage.waitForExistence(timeout: 5))
    }

    @MainActor func testDelayedSpanishTrainKeepsZaragozaAheadAfterTheTimetableHasPassed() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-SpainDelayedStopQA"]
        app.launch()
        let row = updates(in: app, containing: "Arrival at Zaragoza-Delicias unconfirmed")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        if !row.isHittable { app.scrollJourneyContent(to: row) }
        XCTAssertTrue(row.label.contains("Position updated by the feed"), row.label)
        requestNativeCapture(role: "spain-delay")
        capture(app, "Delayed Spanish train before Zaragoza")
        row.tap()
        XCTAssertTrue(app.navigationBars["Recent Updates"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Arrival estimated 25 min late")).firstMatch.exists)
    }

    @MainActor func testRecoveredAmtrakFeedRemembersPriorChanges() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AmtrakSignalGapQA", "-TripUpdatesRecoveryQA"]
        app.launch()
        let row = updates(in: app, containing: "Train position reporting again")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        if !row.isHittable { app.scrollJourneyContent(to: row) }
        row.tap()
        XCTAssertTrue(app.navigationBars["Recent Updates"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Track changed from 4 to 7")).firstMatch.exists)
    }

    @MainActor func testSpainTimetableWithPhoneUpstreamCannotClaimArrivalOrTrainGPS() throws {
        let device = XCUIDevice.shared
        let savedLocation = device.location
        defer { device.location = savedLocation }
        // Simulate the passenger's phone near Calatayud, west of Zaragoza. There is no
        // operator coordinate or dated passage in this separate timetable-only replay.
        device.location = XCUILocation(location: CLLocation(latitude: 41.354, longitude: -1.643))
        let app = XCUIApplication()
        app.launchArguments = ["-SpainTimetablePhoneQA"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Next scheduled stop"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Arrival at Zaragoza-Delicias unconfirmed"].firstMatch.exists)
        XCTAssertFalse(app.buttons["recentTrainUpdates"].exists)
        XCTAssertFalse(app.staticTexts["Arrived"].exists)
        XCTAssertFalse(app.staticTexts["Live train position"].exists)
        requestNativeCapture(role: "spain-timetable")
        capture(app, "Spanish timetable with phone upstream and no operator position")
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let item = XCTAttachment(screenshot: app.screenshot())
        item.name = name
        item.lifetime = .keepAlways
        add(item)
    }

    @MainActor private func updates(in app: XCUIApplication, containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "recentTrainUpdates", text)).firstMatch
    }
}

import XCTest

final class FeaturedTrainDiscoveryUITests: XCTestCase {
    @MainActor
    func testRetryRevealsANamedRouteAndFollowsTheFeaturedTrain() {
        let app = XCUIApplication()
        app.launchArguments = ["-FirstRunPreviewRetry", "-AppStorePreviewTrack", "-calendarSuggestions.v1.introductionDismissed", "YES"]
        app.launch()
        let grabber = app.descendants(matching: .any)["journeyDrawerGrabber"]
        if grabber.exists {
            for _ in 0..<2 where grabber.value as? String != "Full height" { grabber.tap() }
        }
        let retry = app.buttons["retryFeaturedTrain"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        retry.tap()
        let follow = app.buttons["followFirstRunTrain"]
        XCTAssertTrue(follow.waitForExistence(timeout: 10))
        let ticket = app.descendants(matching: .any).matching(identifier: "firstRunTicket").firstMatch
        let station = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Washington Union")).firstMatch
        XCTAssertTrue(ticket.exists)
        XCTAssertTrue(station.exists)
        follow.tap()
        XCTAssertTrue(app.leadingTrain("us:amtraker:171:today").waitForExistence(timeout: 10))
    }
}

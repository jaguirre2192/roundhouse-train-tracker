import XCTest

final class WatchingTrainFlowTests: XCTestCase {
    @MainActor
    func testFollowFeaturedThenClaimOnlyTheSectionRidden() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        if environment["ROUNDHOUSE_TEST_ORIENTATION"] == "landscapeLeft" { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = XCUIApplication()
        let appearance = environment["ROUNDHOUSE_REVIEW_APPEARANCE"] ?? "light"
        app.launchArguments = ["-FirstRunPreviewRetry", "-AppStorePreviewTrack", "-preference.appearance", appearance,
                               "-calendarSuggestions.v1.introductionDismissed", "YES"]
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
        follow.tap()
        let claim = app.buttons["markTrainAsRidden"].firstMatch
        XCTAssertTrue(claim.waitForExistence(timeout: 10))
        requestNativeCapture(role: "watching")
        claim.tap()
        let save = app.buttons["saveRiddenSection"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        let from = app.buttons["rideBoarding"]
        XCTAssertTrue(from.waitForExistence(timeout: 5))
        from.tap()
        let stop = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Baltimore")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        requestNativeCapture(role: "your-ride")
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        XCTAssertTrue(claim.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.leadingTrain("us:amtraker:171:today").waitForExistence(timeout: 8))
    }
}

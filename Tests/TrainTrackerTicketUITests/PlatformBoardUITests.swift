import UIKit
import XCTest

final class PlatformBoardUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor func testBoardingPlatformOpensStoredOriginal() throws {
        setReviewOrientation()
        let app = XCUIApplication()
        app.launchArguments = ["-PlatformBoardQA"]
        if let appearance = ProcessInfo.processInfo.environment["ROUNDHOUSE_REVIEW_APPEARANCE"] {
            app.launchArguments += ["-preference.appearance", appearance]
        }
        app.launch()
        let openBoard = app.buttons["openPlatformBoard"].firstMatch
        XCTAssertTrue(openBoard.waitForExistence(timeout: 15))
        if !openBoard.isHittable { app.scrollJourneyContent(to: openBoard) }
        openBoard.tap()
        let number = app.descendants(matching: .any)["platformNumber"].firstMatch
        XCTAssertTrue(number.waitForExistence(timeout: 10))
        XCTAssertEqual(number.label, "Changed from 4 to 7")
        XCTAssertTrue(app.staticTexts["Vía · Platform changed"].exists)
        let ticket = app.buttons["platformShowTicket"]
        XCTAssertTrue(ticket.waitForExistence(timeout: 5))
        let map = app.descendants(matching: .any)["platformRouteMap"].firstMatch
        if UIDevice.current.userInterfaceIdiom == .phone, app.windows.firstMatch.frame.width >= 620 {
            XCTAssertTrue(map.exists)
        }
        if map.exists {
            XCTAssertFalse(app.navigationBars.staticTexts["Platform View"].exists)
            let status = map.descendants(matching: .any)["journeyPositionStatus"].firstMatch
            XCTAssertTrue(status.exists)
            XCTAssertGreaterThan(status.frame.minX, ticket.frame.maxX)
        }
        requestNativeCapture(role: "platform-board")
        capture(app, "Platform View with an operator track change")
        ticket.tap()
        XCTAssertTrue(app.navigationBars["Original Ticket"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.descendants(matching: .any)["platformOriginalDocument"].firstMatch.waitForExistence(timeout: 6))
        app.buttons["Done"].tap()
        XCTAssertTrue(number.waitForExistence(timeout: 6))
    }

    @MainActor func testDepartureLockScreenSign() throws {
        setReviewOrientation()
        let app = XCUIApplication()
        app.launchArguments = ["-LiveActivityPreview", "-LiveActivityScenario", "platform-changed"]
        if let appearance = ProcessInfo.processInfo.environment["ROUNDHOUSE_REVIEW_APPEARANCE"] {
            app.launchArguments += ["-preference.appearance", appearance]
        }
        app.launch()
        let sign = app.descendants(matching: .any)["boardingLockScreenSign"].firstMatch
        XCTAssertTrue(sign.waitForExistence(timeout: 10))
        XCTAssertTrue(sign.label.contains("Track changed 12"), sign.label)
        XCTAssertTrue(sign.label.contains("Estimated departure"), sign.label)
        requestNativeCapture(role: "boarding-lock")
        capture(app, "Boarding Lock Screen presentation")
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

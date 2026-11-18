import XCTest

final class TicketPurchaseFlowTests: XCTestCase {
    @MainActor
    func testTicketImportRemainsVisibleWithSavedJourneys() {
        verifyTicketImportFromTrips(accessibilitySize: false)
    }

    @MainActor
    func testTicketImportRemainsReachableAtAccessibilitySize() {
        verifyTicketImportFromTrips(accessibilitySize: true)
    }

    @MainActor
    private func verifyTicketImportFromTrips(accessibilitySize: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-JourneyPlanPreview"]
        if accessibilitySize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let alert = app.alerts["Forwarded Tickets"]
        if alert.waitForExistence(timeout: 3) { alert.buttons["OK"].tap() }
        let addTicket = app.homeAction("addJourneyFromTrips")
        XCTAssertTrue(addTicket.waitForExistence(timeout: 10))
        XCTAssertTrue(addTicket.isHittable)
        capture(app, name: "My Trips with persistent ticket action")
        addTicket.tap()
        XCTAssertTrue(app.navigationBars["Add Journey"].waitForExistence(timeout: 5))
        let calendar = app.buttons["Import from Calendar"]
        for _ in 0..<6 where !calendar.isHittable { app.swipeUp() }
        XCTAssertTrue(calendar.isHittable)
        capture(app, name: "Ticket import from My Trips")
        app.buttons["Close"].tap()
        XCTAssertTrue(addTicket.waitForExistence(timeout: 5))
        XCTAssertTrue(addTicket.isHittable)
    }

    @MainActor
    func testSelectedJourneyOpensRetailerAndReturnsToMatchingDetails() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TicketPurchasePreviewEntry", "-TicketPurchasePreviewPersistent", "-TicketPurchasePreviewReset"]
        app.launch()
        let entry = app.buttons["checkJourneyTickets"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.tap()
        let retailer = app.buttons["continueToTicketRetailer"]
        XCTAssertTrue(retailer.waitForExistence(timeout: 5))
        retailer.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20))
        let retailerContent = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "train")).firstMatch
        XCTAssertTrue(retailerContent.waitForExistence(timeout: 45))
        capture(app, name: "Retailer browser")
        done.tap()
        XCTAssertTrue(app.staticTexts["Your journey is still here"].waitForExistence(timeout: 5))
        for _ in 0..<5 where !app.buttons["importPurchasedTicket"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["importPurchasedTicket"].isHittable)
        capture(app, name: "Returned journey and import controls")
        app.buttons["importPurchasedTicket"].tap()
        XCTAssertTrue(app.navigationBars["Add Journey"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        app.terminate()
        app.launchArguments = ["-TicketPurchasePreviewSaved", "-TicketPurchasePreviewPersistent"]
        app.launch()
        let resume = app.buttons["resumeTicketSearch"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        capture(app, name: "Saved search after restart")
        resume.tap()
        XCTAssertTrue(app.staticTexts["Your journey is still here"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
    }

    @MainActor
    func testFailedRetailerLoadKeepsJourneyAndOffersRecovery() {
        let app = XCUIApplication()
        app.launchArguments = ["-TicketPurchasePreview", "-TicketRetailerFailurePreview"]
        app.launch()
        app.buttons["continueToTicketRetailer"].tap()
        XCTAssertTrue(app.staticTexts["ticketPurchaseError"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Open in Safari"].exists)
        XCTAssertTrue(app.buttons["Try Omio Again"].exists)
        capture(app, name: "Retailer load failure recovery")
    }

    @MainActor
    func testAccessibilitySizeCanReachItineraryCopyAndImport() {
        let app = XCUIApplication()
        app.launchArguments = ["-TicketPurchasePreview", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        capture(app, name: "Accessibility top")
        for _ in 0..<12 where !app.buttons["continueToTicketRetailer"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["continueToTicketRetailer"].isHittable)
        capture(app, name: "Accessibility retailer action")
        for _ in 0..<12 where !app.staticTexts["Amtrak 176"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Amtrak 176"].isHittable)
        capture(app, name: "Accessibility outbound")
        let arrivals = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Arrives "))
        for _ in 0..<12 where !arrivals.element(boundBy: 0).isHittable { app.swipeUp() }
        XCTAssertTrue(arrivals.element(boundBy: 0).isHittable)
        capture(app, name: "Accessibility outbound arrival")
        for _ in 0..<12 where !app.staticTexts["Amtrak 177"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Amtrak 177"].isHittable)
        capture(app, name: "Accessibility return")
        for _ in 0..<12 where !arrivals.element(boundBy: 1).isHittable { app.swipeUp() }
        XCTAssertTrue(arrivals.element(boundBy: 1).isHittable)
        capture(app, name: "Accessibility return arrival")
        for _ in 0..<12 where !app.buttons["Copy Journey Details"].isHittable { app.swipeUp() }
        app.buttons["Copy Journey Details"].tap()
        XCTAssertTrue(app.buttons["Journey Details Copied"].exists)
        for _ in 0..<12 where !app.buttons["importPurchasedTicket"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["importPurchasedTicket"].isHittable)
        app.swipeUp() // Place the complete bottom action above the home indicator for visual inspection.
        capture(app, name: "Accessibility copy and import")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

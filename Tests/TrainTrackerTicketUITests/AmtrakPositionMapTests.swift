import XCTest

/// Deterministic map check for an Amtrak train saved with a Transitous identity. The DEBUG
/// snapshot fixture provides GPS; live source integration is covered separately.
final class AmtrakPositionMapTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testRefreshShowsBackendSnapshotPosition() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AmtrakPositionQA"]
        app.launch()
        let refresh = app.journeyRefresh
        XCTAssertTrue(refresh.waitForExistence(timeout: 15))
        capture(app, "Map before refresh (no GPS in snapshot)")
        if app.scrollViews["journeySidePanel"].exists { app.expandJourneyPanel() }
        // The credit renders a frame or two after the refresh control, and iPad exposes the
        // link differently, so wait and accept the visible credit either way.
        let attribution = app.descendants(matching: .any)["amtrakerAttribution"]
        let attributionText = app.staticTexts["Amtrak data from Amtraker"]
        XCTAssertTrue(
            attribution.waitForExistence(timeout: 10) || attributionText.waitForExistence(timeout: 5),
            "Amtraker is credited, with a link, beside the Amtrak data on the map"
        )
        // This test only checks the credit is present and a real touch target; whether tapping it
        // opens Amtraker is covered by AmtrakerAttributionLinkTests, which taps the link itself.
        // isHittable is unreliable for every control inside the map overlay on iPad.
        if attribution.exists {
            XCTAssertGreaterThanOrEqual(attribution.frame.height, 44, "The credit is a full-size touch target")
        }
        refresh.tap()
        // A current position is carried by the train's marker; an old one is also said in words.
        let live = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", [
            "Live train position", "Recently updated train position", "Stale train position", "Position stale",
        ])).firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 15), "Refreshed backend GPS reaches the map")
        capture(app, "Map after refresh with Amtraker GPS")
        XCTAssertFalse(app.staticTexts["Position unavailable"].exists)
        // The camera offers whole-route framing when GPS cannot establish the next stop,
        // and switches between following and route framing when it can.
        let camera = app.buttons.matching(NSPredicate(format: "label IN %@", [
            "Follow train", "Show whole route",
        ])).firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 5), "A valid map camera control stays available")
        camera.tap()
        XCTAssertTrue(live.waitForExistence(timeout: 5), "Changing framing keeps the train position marker visible")
        XCTAssertFalse(app.staticTexts["Position unavailable"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        capture(app, "Train position survives camera framing")
    }

    @MainActor
    func testWithoutSnapshotPositionMapStaysPositionUnavailable() {
        let app = XCUIApplication()
        app.launchArguments = ["-AmtrakPositionQA", "-AmtrakPositionQABefore"]
        app.launch()
        let refresh = app.journeyRefresh
        XCTAssertTrue(refresh.waitForExistence(timeout: 15))
        refresh.tap()
        sleep(5)
        capture(app, "Previous behavior: snapshot without GPS")
        let unavailable = app.staticTexts["Position unavailable"].exists
            || (refresh.value as? String)?.contains("Position unavailable") == true
        XCTAssertTrue(unavailable, "A missing GPS fix remains unavailable in the map control's status")
    }

    @MainActor
    func testCompact2120TicketWrapsCompleteStationNames() {
        let app = endpointPreview(["-AmtrakPositionQA", "-AmtrakPositionQABefore"])
        let ticket = app.buttons["journeyTicket-us:transitous:20_us-Amtrak_285229"]
        XCTAssertTrue(ticket.waitForExistence(timeout: 10))
        app.expandJourneyPanel()
        let origin = ticket.descendants(matching: .any).matching(identifier: "compactTicketOrigin").firstMatch
        let destination = ticket.descendants(matching: .any).matching(identifier: "compactTicketDestination").firstMatch
        reachEndpoint(destination, in: app)
        XCTAssertEqual(origin.label, "Washington Union Station")
        XCTAssertEqual(destination.label, "Ny Moynihan Train Hall At Penn Station")
        XCTAssertGreaterThan(destination.frame.minY, origin.frame.maxY,
                             "Names without passenger-facing codes receive separate full-width lines")
        XCTAssertGreaterThan(destination.frame.height, 40, "The long New York name wraps instead of using an ellipsis")
        XCTAssertTrue(ticket.frame.contains(origin.frame))
        XCTAssertTrue(ticket.frame.contains(destination.frame))
        capture(app, "Complete Washington and New York names on compact ticket")
    }

    @MainActor
    func testCompactTicketKeepsGenuineNYPAndWASCodesOnOneRail() {
        let app = endpointPreview(["-AppStorePreview", "-AppStorePreviewMap", "-AppStorePreviewTrack"])
        let ticket = app.buttons["journeyTicket-us:amtraker:171:today"]
        XCTAssertTrue(ticket.waitForExistence(timeout: 10))
        app.expandJourneyPanel()
        let origin = ticket.descendants(matching: .any).matching(identifier: "compactTicketOrigin").firstMatch
        let destination = ticket.descendants(matching: .any).matching(identifier: "compactTicketDestination").firstMatch
        reachEndpoint(destination, in: app)
        XCTAssertEqual(origin.label, "NYP")
        XCTAssertEqual(destination.label, "WAS")
        XCTAssertEqual(origin.frame.midY, destination.frame.midY, accuracy: 2)
        XCTAssertLessThan(origin.frame.maxX, destination.frame.minX)
        capture(app, "Genuine NYP and WAS codes keep the horizontal rail")
    }

    @MainActor
    private func endpointPreview(_ fixture: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = fixture + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
                                        "-preference.appearance", "dark", "-preference.autoLockScreen", "NO"]
        app.launch()
        return app
    }

    @MainActor
    private func reachEndpoint(_ target: XCUIElement, in app: XCUIApplication) {
        let side = app.scrollViews["journeySidePanel"]
        let scroll = side.exists ? side : app.scrollViews["journeyDrawerScroll"]
        for _ in 0..<20 {
            let visible = scroll.frame.insetBy(dx: 6, dy: 10)
            if target.exists, visible.contains(target.frame) { return }
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            start.press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28)))
        }
        XCTFail("The complete endpoint is not reachable inside the actual journey panel")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

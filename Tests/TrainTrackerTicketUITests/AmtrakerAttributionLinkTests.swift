import XCTest

/// Amtraker's licence requires a working credit, so this taps the credit on the map and checks it
/// actually opens amtraker.com in the browser. XCUITest reports `isHittable` false for every
/// control inside the map overlay on iPad, so the tap falls back to the element's own coordinate.
final class AmtrakerAttributionLinkTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testTappingTheMapCreditOpensAmtrakerInTheBrowser() {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        defer { safari.terminate() }
        let app = XCUIApplication()
        app.launchArguments = ["-AmtrakPositionQA"]
        app.launch()

        let credit = app.descendants(matching: .any)["amtrakerAttribution"]
        XCTAssertTrue(credit.waitForExistence(timeout: 20), "The map credits Amtraker with a link")
        XCTAssertEqual(credit.label, "Amtrak data from Amtraker")
        XCTAssertGreaterThanOrEqual(credit.frame.height, 44, "The credit is a full-size touch target")
        // The credit sits in the journey panel, under the stops.
        app.scrollJourneyContent(to: credit)
        add(named(XCTAttachment(screenshot: app.screenshot()), "Map credit before tapping"))

        let reportsHittable = credit.isHittable
        add(named(XCTAttachment(string: "credit isHittable = \(reportsHittable)"), "Credit hit-test report"))
        if reportsHittable {
            credit.tap()
        } else {
            credit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        XCTAssertTrue(
            safari.wait(for: .runningForeground, timeout: 30),
            "Tapping the credit opens the link in the browser"
        )
        let opened = openedURL(in: safari)
        add(named(XCTAttachment(screenshot: XCUIScreen.main.screenshot()), "Amtraker opened from the credit"))
        XCTAssertTrue(opened.contains("amtraker.com"), "The credit points at Amtraker, got \(opened)")
        add(named(XCTAttachment(string: opened), "Address the credit opened"))
    }

    /// Safari exposes the address differently per idiom and while a page loads, so read whichever
    /// field carries it.
    @MainActor
    private func openedURL(in safari: XCUIApplication) -> String {
        let deadline = Date().addingTimeInterval(20)
        var seen = ""
        while Date() < deadline {
            let candidates = [safari.textFields["URL"], safari.textFields.firstMatch, safari.otherElements["URL"]]
            for candidate in candidates where candidate.exists {
                let value = (candidate.value as? String) ?? candidate.label
                if !value.isEmpty { seen = value }
                if value.contains("amtraker") { return value }
            }
            _ = safari.wait(for: .runningForeground, timeout: 1)
        }
        return seen
    }

    private func named(_ attachment: XCTAttachment, _ name: String) -> XCTAttachment {
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}

import XCTest

@MainActor
final class AnnualRailPrintUITests: XCTestCase {
    func testOpensAnnualPrintAndSharesArtwork() {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let orientation = environment["ROUNDHOUSE_TEST_ORIENTATION"] ?? environment["TEST_RUNNER_ROUNDHOUSE_TEST_ORIENTATION"]
        XCUIDevice.shared.orientation = orientation == "landscapeLeft" ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        let appearance = environment["ROUNDHOUSE_REVIEW_APPEARANCE"] ?? environment["TEST_RUNNER_ROUNDHOUSE_REVIEW_APPEARANCE"] ?? "light"
        app.launchArguments = ["-AppStorePreview", "-AppStorePreviewSettings",
            "-preference.appearance", appearance, "-calendarSuggestions.v1.introductionDismissed", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let notice = app.alerts["Forwarded Tickets"]
        if notice.exists { notice.buttons["OK"].tap() }

        let archive = app.descendants(matching: .any).matching(identifier: "travelLogFromSettings").firstMatch
        let account = app.descendants(matching: .any).matching(identifier: "settingsAccountColumn").firstMatch
        if !account.waitForExistence(timeout: 1) { XCTAssertTrue(app.staticTexts["Settings"].firstMatch.waitForExistence(timeout: 8)) }
        reveal(archive, in: account.exists ? account : app)
        archive.tap()

        let printLink = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "annualPrint-")).firstMatch
        reveal(printLink, in: app)
        printLink.tap()
        let proof = app.descendants(matching: .any).matching(identifier: "annualPrintProof").firstMatch
        XCTAssertTrue(proof.waitForExistence(timeout: 8))
        let share = app.buttons["shareAnnualPrint"]
        XCTAssertTrue(share.exists)
        let spread = app.descendants(matching: .any).matching(identifier: "annualPrintSpread").firstMatch
        if orientation == "landscapeLeft" { XCTAssertTrue(spread.exists) }
        if spread.exists {
            XCTAssertLessThanOrEqual(proof.frame.maxX, share.frame.minX, "The printed page and actions occupy separate panes")
        }

        requestNativeCapture(role: "annual-print")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "annual-print"
        attachment.lifetime = .keepAlways
        add(attachment)
        reveal(share, in: app)
        share.tap()
        let systemShare = app.otherElements["ActivityListView"]
        XCTAssertTrue(systemShare.waitForExistence(timeout: 8))
        let copy = systemShare.collectionViews["activityCollectionView"].cells.matching(NSPredicate(format: "label == %@", "Copy")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        let shareCapture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shareCapture.name = "annual-print-share"
        shareCapture.lifetime = .keepAlways
        add(shareCapture)
        requestNativeCapture(role: "annual-print-share")
        copy.tap()
        XCTAssertTrue(systemShare.waitForNonExistence(timeout: 8), "Copy should complete and dismiss the native share sheet")
        XCTAssertTrue(proof.waitForExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement, in scope: XCUIElement) {
        if element.waitForExistence(timeout: 3), element.isHittable { return }
        for _ in 0..<10 {
            let start = scope.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.84))
            start.press(forDuration: 0.05, thenDragTo: scope.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.32)))
            if element.exists, element.isHittable { return }
        }
        XCTAssertTrue(element.isHittable, "The control is reachable through normal navigation")
    }
}

import StoreKitTest
import XCTest

@MainActor
final class SupportRoundhouseTipUITests: XCTestCase {
  func testSupportFromSettingsAndReturnToFreeApp() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "RoundhouseTips", withExtension: "storekit"))
    let store = try SKTestSession(contentsOf: url)
    store.resetToDefaultState()
    store.clearTransactions()
    store.disableDialogs = true
    store.storefront = "USA"
    defer { store.clearTransactions(); store.resetToDefaultState() }

    let app = XCUIApplication()
    app.launchArguments = ["-AppStorePreview", "-AppStorePreviewSettings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    setReviewOrientation()
    let prefs = app.descendants(matching: .any).matching(identifier: "settingsPreferencesColumn").firstMatch
    let row = app.buttons["settings.supportRoundhouse"]
    let scroll: XCUIElement = prefs.waitForExistence(timeout: 2) ? prefs : app
    for _ in 0..<14 where !row.isHittable { scroll.swipeUp() }
    XCTAssertTrue(row.isHittable, app.debugDescription)
    row.tap()

    let buy = app.buttons["roundhouse.tip.purchase"]
    XCTAssertTrue(buy.waitForExistence(timeout: 12), app.debugDescription)
    XCTAssertTrue(buy.label.contains("0.99"))
    requestNativeCapture(role: "roundhouse-hosting-tip")
    let review = XCTAttachment(screenshot: app.screenshot())
    review.name = "roundhouse-hosting-tip"
    review.lifetime = .keepAlways
    add(review)
    buy.tap()
    XCTAssertTrue(app.staticTexts["Thank you for the tip."].waitForExistence(timeout: 15), app.debugDescription)
    XCTAssertEqual(store.allTransactions().count, 1)
    app.buttons["Done"].tap()
    XCTAssertTrue(row.waitForExistence(timeout: 5))
  }
}

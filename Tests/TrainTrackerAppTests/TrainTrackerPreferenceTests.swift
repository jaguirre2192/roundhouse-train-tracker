import XCTest
import TrainTrackerCore
@testable import TrainTracker

final class TrainTrackerPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "TrainTrackerPreferenceTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTimeFormatFollowsTheDeviceUnlessChosen() {
        let twelve = Locale(identifier: "en_US")
        let twentyFour = Locale(identifier: "en_GB")
        XCTAssertEqual(TimeFormatPreference.system.clockPattern(deviceLocale: twelve), "h:mm a")
        XCTAssertEqual(TimeFormatPreference.system.clockPattern(deviceLocale: twentyFour), "HH:mm")
        XCTAssertEqual(TimeFormatPreference.twentyFourHour.clockPattern(deviceLocale: twelve), "HH:mm")
        XCTAssertEqual(TimeFormatPreference.twelveHour.clockPattern(deviceLocale: twentyFour), "h:mm a")
        XCTAssertEqual(TimeFormatPreference.stored(in: defaults), .system)
        defaults.set("sundial", forKey: TimeFormatPreference.key)
        XCTAssertEqual(TimeFormatPreference.stored(in: defaults), .system)
    }

    func testChosenTimeFormatReachesLocaleDrivenStyles() {
        let date = Date(timeIntervalSince1970: 1_800_000_000 + 14 * 3600)
        let zone = TimeZone(secondsFromGMT: 0)!
        let base = Locale(identifier: "en_US")
        let style = { (locale: Locale) in
            date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: zone))
        }
        XCTAssertFalse(style(TimeFormatPreference.twentyFourHour.locale(basedOn: base)).contains("M"))
        XCTAssertTrue(style(TimeFormatPreference.twelveHour.locale(basedOn: Locale(identifier: "en_GB"))).uppercased().contains("M"))
        XCTAssertEqual(TimeFormatPreference.system.locale(basedOn: base), base)
    }

    func testAlertChoicesDefaultToEverythingAndRejectUnknownThresholds() {
        XCTAssertEqual(AlertPreference.stored(in: defaults), PushPreferences())
        defaults.set(15, forKey: AlertPreference.delayThreshold)
        defaults.set(false, forKey: AlertPreference.disruptions)
        let stored = AlertPreference.stored(in: defaults)
        XCTAssertEqual(stored.delayThresholdMinutes, 15)
        XCTAssertFalse(stored.notifiesDisruptions)
        XCTAssertTrue(stored.notifiesCancellations)
        defaults.set(7, forKey: AlertPreference.delayThreshold)
        XCTAssertEqual(AlertPreference.stored(in: defaults).delayThresholdMinutes, 5)
    }

    func testResetClearsEveryPreferenceAndNothingElse() {
        for key in TrainTrackerPreference.all { defaults.set("x", forKey: key) }
        defaults.set("kept", forKey: "savedTrips")
        TrainTrackerPreference.resetAll(in: defaults)
        for key in TrainTrackerPreference.all { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertEqual(defaults.string(forKey: "savedTrips"), "kept")
    }

    func testAutomaticAppearanceFollowsTheSystem() {
        XCTAssertNil(AppearancePreference.system.colorScheme)
        XCTAssertEqual(AppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppearancePreference.dark.colorScheme, .dark)
    }

    func testOnlySatelliteUsesImageryCasings() {
        XCTAssertEqual(MapStylePreference.allCases.filter(\.usesImagery), [.satellite])
    }

    func testOnlyTheWashesTakeATripsStatus() {
        XCTAssertTrue(BackgroundPreference.moving.takesStatusTint)
        XCTAssertTrue(BackgroundPreference.still.takesStatusTint)
        XCTAssertFalse(BackgroundPreference.plain.takesStatusTint, "A flat page never changes color")
        XCTAssertFalse(BackgroundPreference.paper.takesStatusTint, "Paper never changes color")
        XCTAssertEqual(BackgroundPreference(rawValue: "paper"), .paper)
        XCTAssertFalse(BackgroundPreference.white.takesStatusTint, "White never changes color")
        XCTAssertTrue(BackgroundPreference.white.isFlatSheet)
        XCTAssertTrue(BackgroundPreference.paper.isFlatSheet)
        XCTAssertFalse(BackgroundPreference.moving.isFlatSheet)
        XCTAssertEqual(BackgroundPreference.standard, .white, "The app ships on the white page")
        XCTAssertEqual(BackgroundPreference.allCases.first, .standard, "Settings offers the shipped page first")
    }
}

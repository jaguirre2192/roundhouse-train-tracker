import XCTest
@testable import TrainTracker

final class TrainTrackerSettingsReadinessTests: XCTestCase {
  func testEnabledAlertsPresentTrackedTripsAsReady() {
    let presentation = TrainTrackerSettingsReadiness(
      savedTripCount: 2,
      notificationAccess: .enabled
    )

    XCTAssertEqual(presentation.title, "Tracking is ready")
    XCTAssertEqual(presentation.savedTripText, "2 trips")
    XCTAssertTrue(presentation.detail.contains("change alerts ready"))
  }

  func testDeniedAlertsPreserveRefreshExpectation() {
    let presentation = TrainTrackerSettingsReadiness(
      savedTripCount: 1,
      notificationAccess: .disabled
    )

    XCTAssertEqual(presentation.title, "Alerts are off")
    XCTAssertEqual(presentation.savedTripText, "1 trip")
    XCTAssertTrue(presentation.detail.contains("still refresh normally"))
  }

  func testUnrequestedAlertsWithTripsPromptSetup() {
    let presentation = TrainTrackerSettingsReadiness(
      savedTripCount: 3,
      notificationAccess: .notRequested
    )

    XCTAssertEqual(presentation.title, "Finish alert setup")
  }

  func testEmptyLibraryKeepsTheNextTrainAsThePrimaryTask() {
    let presentation = TrainTrackerSettingsReadiness(
      savedTripCount: 0,
      notificationAccess: .enabled
    )

    XCTAssertEqual(presentation.title, "Ready for your next train")
    XCTAssertEqual(presentation.savedTripText, "0 trips")
  }

  func testCopyNamesTheDeviceTheTripsAreSavedOn() {
    let presentation = TrainTrackerSettingsReadiness(
      savedTripCount: 2,
      notificationAccess: .enabled,
      deviceName: "iPad"
    )

    XCTAssertEqual(presentation.savedTripDetail, "Available on this iPad, even when you're signed out.")
    XCTAssertTrue(presentation.detail.contains("saved on this iPad"))
    XCTAssertFalse(presentation.detail.contains("iPhone"))
  }

  func testDeviceNameFollowsTheIdiomNotTheWindow() {
    XCTAssertEqual(TrainTrackerDeviceName.name(for: .phone, isiOSAppOnMac: false), "iPhone")
    XCTAssertEqual(TrainTrackerDeviceName.name(for: .pad, isiOSAppOnMac: false), "iPad")
    XCTAssertEqual(TrainTrackerDeviceName.name(for: .pad, isiOSAppOnMac: true), "Mac")
    XCTAssertEqual(TrainTrackerDeviceName.name(for: .mac, isiOSAppOnMac: false), "Mac")
  }

  func testPushWarningNamesTheDevice() {
    let presentation = PushDeliveryWarningPresentation(reason: .remoteRegistrationFailed, deviceName: "iPad")

    XCTAssertTrue(presentation.message.localizedCaseInsensitiveContains("this iPad couldn’t register"))
    XCTAssertEqual(presentation.accessibilityHint, "Registers this iPad for train alerts again")
  }
}

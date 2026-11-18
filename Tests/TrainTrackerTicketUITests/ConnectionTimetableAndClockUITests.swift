import XCTest
import UIKit

final class ConnectionTimetableAndClockUITests: XCTestCase {
    @MainActor func testExpandConnectionTimetableAndStillFollowAlternative() throws {
        let app = launch(["-JourneyPlanPreview", "-JourneyPlanPreviewDetail", "-JourneyPlanPreviewOneWay", "-ConnectionRecoveryQA"])
        let panel = scrollPanel(app, identifiers: ["journeyPlanSidePanel", "journeyPlanScroll"])
        let disclosure = panel.buttons["connectionTimetableDisclosure"]
        reveal(disclosure, in: panel)
        let interval = NSPredicate(format: "label == %@", "3 min between trains")
        XCTAssertEqual(panel.staticTexts.matching(interval).count, 1)
        disclosure.tap()
        let shortfall = panel.staticTexts["connectionTransferMargin"]
        reveal(shortfall, in: panel)
        XCTAssertEqual(shortfall.label, "2 min short")
        XCTAssertTrue(panel.staticTexts["Roundhouse planning estimate · 5 min"].exists)
        let chart = panel.descendants(matching: .any)["connectionTimetableChart"].firstMatch
        XCTAssertEqual(chart.staticTexts.matching(interval).count, 0)
        reveal(disclosure, in: panel)
        capture(app, role: "connection-timetable", name: "Updated arrival and onward departure in Brussels")
        let follow = panel.buttons["followConnectionAlternative"]
        reveal(follow, in: panel)
        follow.tap()
        XCTAssertTrue(panel.buttons["viewFollowedAlternative"].waitForExistence(timeout: 8))
    }

    @MainActor func testPublishedTransferBandAtWienerNeustadt() throws {
        let app = launch(["-JourneyPlanPreviewDetail", "-JourneyPlanPreviewOneWay", "-PublishedConnectionQA"])
        let panel = scrollPanel(app, identifiers: ["journeyPlanSidePanel", "journeyPlanScroll"])
        let disclosure = panel.buttons["connectionTimetableDisclosure"]
        reveal(disclosure, in: panel)
        disclosure.tap()
        let source = panel.descendants(matching: .any)["publishedTransferMinimum"].firstMatch
        reveal(source, in: panel)
        XCTAssertTrue(source.label.contains("Published minimum 5 min") && source.label.contains("ÖBB-Infrastruktur"), source.label)
        XCTAssertEqual(panel.staticTexts["connectionTransferMargin"].label, "27 min to spare")
        XCTAssertTrue(panel.staticTexts["32 min between trains"].exists)
        reveal(disclosure, in: panel)
        capture(app, role: "connection-published", name: "Published transfer allowance from ÖBB at Wiener Neustadt")
    }

    @MainActor func testTapParisArrivalToCompareStationClocks() throws {
        let app = launch(["-StationClocksQA", "-AppStorePreviewMap"])
        if UIDevice.current.userInterfaceIdiom == .pad {
            let hideSidebar = app.buttons["Hide Sidebar"].firstMatch
            if hideSidebar.exists, hideSidebar.isHittable { hideSidebar.tap() }
        }
        let panel = scrollPanel(app, identifiers: ["journeySidePanel", "journeyDrawerScroll"])
        let expand = panel.buttons["journeyExpandDetails"]
        if expand.exists {
            if expand.value as? String != "Expanded" {
                reveal(expand, in: panel)
                expand.tap()
            }
        } else {
            let grabber = app.buttons["journeyDrawerGrabber"].firstMatch
            for _ in 0..<2 where grabber.exists && grabber.value as? String != "Full height" {
                let visible = grabber.frame.intersection(app.windows.firstMatch.frame)
                guard !visible.isEmpty else { break }
                let window = app.windows.firstMatch
                window.coordinate(withNormalizedOffset: .zero).withOffset(.init(
                    dx: visible.midX - window.frame.minX, dy: visible.midY - window.frame.minY)).tap()
            }
        }
        let time = panel.buttons["routeClockTime-eurostar:PNO#1"]
        reveal(time, in: panel)
        XCTAssertTrue(panel.buttons["routeClockChange"].label.contains("1 hour ahead"))
        time.tap()
        let local = panel.descendants(matching: .any)["stationClockArrival"].firstMatch
        let origin = panel.descendants(matching: .any)["stationClockPrevious"].firstMatch
        reveal(origin, in: panel)
        XCTAssertTrue(local.label.contains("Paris Nord") && local.label.contains("10:21"), local.label)
        XCTAssertTrue(origin.label.contains("London St Pancras") && origin.label.contains("9:21"), origin.label)
        capture(app, role: "station-clocks", name: "Eurostar arrival at Paris and London time")
        let marker = panel.buttons["routeClockChange"]
        reveal(marker, in: panel)
        marker.tap()
        XCTAssertEqual(marker.value as? String, "Collapsed")
    }

    @MainActor private func launch(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        setReviewOrientation()
        let appearance = env["ROUNDHOUSE_REVIEW_APPEARANCE"] ?? env["TEST_RUNNER_ROUNDHOUSE_REVIEW_APPEARANCE"] ?? "light"
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-preference.appearance", appearance, "-preference.autoLockScreen", "NO",
                                         "-calendarSuggestions.v1.enabled", "NO", "-calendarSuggestions.v1.introductionDismissed", "YES"]
        app.launch()
        return app
    }

    @MainActor private func scrollPanel(_ app: XCUIApplication, identifiers: [String]) -> XCUIElement {
        let candidates = app.scrollViews.matching(NSPredicate(format: "identifier IN %@", identifiers))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 12))
        return app.visibleJourneyPanel(identifiers: identifiers)
    }

    @MainActor private func reveal(_ target: XCUIElement, in panel: XCUIElement) {
        let window = XCUIApplication().windows.firstMatch
        for _ in 0..<16 {
            let bounds = panel.frame.intersection(window.frame).insetBy(dx: 4, dy: 12)
            if target.exists, bounds.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)), target.isHittable { return }
            guard !bounds.isEmpty else { break }
            let forward = !target.exists || target.frame.midY > bounds.midY
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let x = bounds.minX + bounds.width * (UIDevice.current.userInterfaceIdiom == .pad ? 0.75 : 0.55) - window.frame.minX
            let start = origin.withOffset(.init(dx: x, dy: bounds.minY + bounds.height * (forward ? 0.76 : 0.29) - window.frame.minY))
            let end = origin.withOffset(.init(dx: x, dy: bounds.minY + bounds.height * (forward ? 0.43 : 0.62) - window.frame.minY))
            start.press(forDuration: 0.10, thenDragTo: end)
        }
        XCTFail("Could not reach the requested control in the visible journey panel")
    }

    @MainActor private func capture(_ app: XCUIApplication, role: String, name: String) {
        requestNativeCapture(role: role)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

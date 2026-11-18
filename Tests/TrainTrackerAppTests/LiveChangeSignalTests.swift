import XCTest
@testable import TrainTracker

final class LiveChangeSignalTests: XCTestCase {
    private let base = LiveChangeSignal(platform: "7", platformNoun: "Track", isConfirmed: true)

    func testSavedDetailsNeverAnnounceThemselves() {
        let saved = LiveChangeSignal(platform: "7", platformNoun: "Track")
        XCTAssertNil(LiveChangeSignal.change(from: saved, to: base), "the first confirmed check is not a change")
        XCTAssertNil(LiveChangeSignal.change(from: base, to: saved))
    }

    func testTrackChangeIsAnnouncedWithItsNoun() {
        var moved = base
        moved.platform = "9"
        XCTAssertEqual(LiveChangeSignal.change(from: base, to: moved), .platform("9"))
        XCTAssertEqual(moved.announcement(for: .platform("9")), "Track 9")
        var lost = base
        lost.platform = nil
        XCTAssertNil(LiveChangeSignal.change(from: base, to: lost), "a dropped assignment is unknown, not news")
    }

    func testDelayAnnouncedOnlyWhenItGrowsByFiveMinutes() {
        var small = base
        small.delayMinutes = 4
        XCTAssertNil(LiveChangeSignal.change(from: base, to: small))
        var late = base
        late.delayMinutes = 8
        XCTAssertEqual(LiveChangeSignal.change(from: small, to: late), nil, "4 to 8 is under five more minutes")
        XCTAssertEqual(LiveChangeSignal.change(from: base, to: late), .later(minutes: 8))
        XCTAssertEqual(late.announcement(for: .later(minutes: 8)), "Now 8 minutes late")
    }

    func testCancellationOutranksOtherChanges() {
        var cancelled = base
        cancelled.isCancelled = true
        cancelled.platform = "9"
        XCTAssertEqual(LiveChangeSignal.change(from: base, to: cancelled), .cancelled)
    }
}

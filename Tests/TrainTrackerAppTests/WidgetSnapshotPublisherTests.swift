import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class WidgetSnapshotPublisherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSnapshotUsesRealStationCodesAndAmtrakTracks() throws {
        let snapshot = WidgetSnapshotPublisher.snapshot(trips: [amtrakTrip()], plans: [], at: now)
        let train = try XCTUnwrap(snapshot.trains.first)
        XCTAssertEqual(train.boarding?.code, "NYP")
        XCTAssertNil(train.alighting?.code, "a numeric-only identifier is never shown as a code")
        XCTAssertEqual(train.boarding?.platformNoun, "Track")
        let presentation = WidgetTrainPresentation(train: train, at: now)
        XCTAssertEqual(presentation.platformText, "Track 9")
        XCTAssertTrue(presentation.inlineText.hasPrefix("NYP "))
        XCTAssertEqual(train.deepLinkURL?.host, "journey")
    }

    func testTripChangesWriteOnceAndReloadOnlyWhenTheSnapshotChanges() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "widget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(
            store: WidgetSnapshotStore(fileURL: url), reload: { reloads += 1 }, now: { [now] in now }
        )
        let library = TripLibrary(
            trips: [], pushCoordinator: RecordingPushCoordinator(), archive: nil, automaticRefreshEnabled: false
        )
        publisher.connect(library: library, plans: nil)
        publisher.writeNow()
        XCTAssertEqual(reloads, 1, "the first write records that nothing is tracked")
        XCTAssertEqual(WidgetSnapshotStore(fileURL: url).load()?.trains, [])

        try library.storeTrackedTrip(amtrakTrip())
        XCTAssertNotNil(library.widgetSnapshotNeedsUpdate)
        publisher.writeNow()
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(WidgetSnapshotStore(fileURL: url).load()?.trains.map(\.id), ["us:amtrak:2151"])

        publisher.writeNow()
        XCTAssertEqual(reloads, 2, "an unchanged snapshot does not spend a reload")
    }

    func testSiriAnswerNamesTrainTimeTrackAndSavedDetails() {
        let clock = WidgetClock(locale: Locale(identifier: "en_US"), deviceTimeZone: TimeZone(identifier: "UTC")!)
        let saved = WidgetSnapshotPublisher.snapshot(trips: [amtrakTrip()], plans: [], at: now)
        let answer = NextTrainAnswer(snapshot: saved, at: now, clock: clock).text
        XCTAssertTrue(answer.hasPrefix("Acela 2151 is scheduled to leave from New York Penn at "), answer)
        XCTAssertTrue(answer.contains(" Track 9."), answer)
        XCTAssertTrue(answer.hasSuffix("open Roundhouse to check live times."), answer)

        let checked = WidgetSnapshotPublisher.snapshot(trips: [amtrakTrip()], plans: [], at: now,
                                                       lastSuccessfulCheck: { [now] _ in now })
        XCTAssertFalse(NextTrainAnswer(snapshot: checked, at: now, clock: clock).text.contains("saved details"))
    }

    func testSiriAnswerWithNothingTrackedOffersToAddAJourney() {
        let empty = WidgetSnapshotPublisher.snapshot(trips: [], plans: [], at: now)
        XCTAssertEqual(NextTrainAnswer(snapshot: empty, at: now).text,
                       "You have no upcoming trains in Roundhouse. Add a journey and I can tell you when it leaves.")
    }

    private func amtrakTrip() -> TrainTrip {
        func call(_ code: String, _ id: String, _ sequence: Int, arrival: Double?, departure: Double?) -> StopTime {
            StopTime(
                station: Station(
                    id: RailIdentifier(rawValue: "us:amtrak:\(id)"), names: [LocalizedStationName(code)],
                    codes: [.sourceNative: id], location: GeoCoordinate(latitude: 0, longitude: 0), countryCode: "US"
                ),
                sequence: sequence,
                scheduledArrival: arrival.map { now.addingTimeInterval($0 * 60) },
                scheduledDeparture: departure.map { now.addingTimeInterval($0 * 60) },
                plannedPlatform: "9"
            )
        }
        return TrainTrip(
            id: RailIdentifier(rawValue: "us:amtrak:2151"), source: "transitous", serviceDate: now,
            operatorName: "Amtrak", product: "Acela 2151", headsign: "Washington",
            stopTimes: [
                call("New York Penn", "NYP", 1, arrival: nil, departure: 30),
                call("Philadelphia", "12345", 2, arrival: 110, departure: nil),
            ],
            capabilities: RealtimeCapabilities(
                hasPositions: false, hasPlatforms: true, hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop
            )
        )
    }
}

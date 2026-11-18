import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

enum JourneySearchStoreFixtures {
    static let paris = place(
        id: "eu:transitous:fr-paris",
        name: "Paris",
        country: "FR",
        timeZone: "Europe/Paris"
    )
    static let amsterdam = place(
        id: "eu:transitous:nl-amsterdam",
        name: "Amsterdam",
        country: "NL",
        timeZone: "Europe/Amsterdam"
    )

    static func place(
        id: String,
        name: String,
        kind: RailPlace.Kind = .city,
        country: String = "FR",
        timeZone: String = "Europe/Paris"
    ) -> RailPlace {
        RailPlace(
            id: RailIdentifier(rawValue: id),
            kind: kind,
            displayName: name,
            context: kind == .city ? "All stations" : country,
            countryCode: country,
            timeZoneIdentifier: timeZone,
            location: GeoCoordinate(latitude: 48.8566, longitude: 2.3522),
            eligibleModes: ["highSpeedRail"],
            attributions: ["Transitous"]
        )
    }

    static func date(_ value: String) -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            preconditionFailure("Invalid fixture date: \(value)")
        }
        return date
    }

    static func form(
        outboundTime: Date = date("2026-07-24T06:25:00Z"),
        returnTime: Date = date("2026-07-25T06:25:00Z"),
        returnEnabled: Bool = true
    ) -> JourneySearchFormState {
        JourneySearchFormState(
            origin: paris,
            destination: amsterdam,
            outboundTime: outboundTime,
            outboundArriveBy: false,
            returnEnabled: returnEnabled,
            returnTime: returnTime,
            returnArriveBy: false,
            directOnly: false,
            maximumTransfers: 4
        )
    }

    static func option(
        id: String,
        fingerprint: String,
        start: Date,
        end: Date,
        expectedDeparture: Date? = nil,
        expectedArrival: Date? = nil,
        origin: RailPlace = paris,
        destination: RailPlace = amsterdam,
        transferCount: Int = 0,
        token: String? = nil,
        tripID: String? = nil,
        trainNumber: String = "9315",
        isTrackable: Bool = true,
        untrackableReason: String? = nil
    ) -> JourneyOption {
        let from = JourneyCall(
            place: origin,
            city: origin.kind == .city ? origin : nil,
            scheduledArrival: nil,
            scheduledDeparture: start,
            expectedArrival: nil,
            expectedDeparture: expectedDeparture,
            plannedPlatform: nil,
            expectedPlatform: nil,
            isCancelled: false
        )
        let to = JourneyCall(
            place: destination,
            city: destination.kind == .city ? destination : nil,
            scheduledArrival: end,
            scheduledDeparture: nil,
            expectedArrival: expectedArrival,
            expectedDeparture: nil,
            plannedPlatform: nil,
            expectedPlatform: nil,
            isCancelled: false
        )
        let rail = RailJourneySegment(
            id: "\(id)-rail",
            tripID: isTrackable
                ? RailIdentifier(rawValue: tripID ?? "eu:transitous:\(id)-trip")
                : nil,
            serviceDate: start,
            operatorName: "Example Rail",
            product: "High speed",
            trainNumber: trainNumber,
            trainName: nil,
            from: from,
            to: to,
            intermediateCalls: [],
            isCancelled: false,
            isRealtime: false,
            isTrackable: isTrackable,
            untrackableReason: untrackableReason
        )
        return JourneyOption(
            id: id,
            fingerprint: fingerprint,
            startTime: start,
            endTime: end,
            duration: end.timeIntervalSince(start),
            transferCount: transferCount,
            segments: [.rail(rail)],
            badges: transferCount == 0 ? [.direct] : [],
            trackability: JourneyTrackability(
                trackableRailSegments: isTrackable ? 1 : 0,
                totalRailSegments: 1
            ),
            realtimeFreshness: nil,
            attributions: ["Transitous"],
            trackingToken: token ?? "token-\(id)"
        )
    }

    static func page(
        options: [JourneyOption],
        previous: String? = nil,
        next: String? = nil
    ) -> JourneySearchPage {
        JourneySearchPage(
            generatedAt: date("2026-07-21T12:00:00Z"),
            expiresAt: date("2026-07-21T12:10:00Z"),
            options: options,
            previousCursor: previous,
            nextCursor: next,
            warnings: [],
            attributions: ["Transitous"]
        )
    }

    @MainActor
    static func resolution(
        outbound: JourneyOption,
        outboundTrips: [TrainTrip],
        outboundFailures: [(String, JourneyPlanResolution.Failure)] = [],
        returnOption: JourneyOption? = nil,
        returnTrips: [TrainTrip] = [],
        returnFailures: [(String, JourneyPlanResolution.Failure)] = []
    ) -> JourneyPlanResolution {
        var directions = [direction(
            option: outbound,
            trips: outboundTrips,
            failures: outboundFailures
        )]
        if let returnOption {
            directions.append(direction(
                option: returnOption,
                trips: returnTrips,
                failures: returnFailures
            ))
        }
        return JourneyPlanResolution(directions: directions)
    }

    static func failure(
        code: JourneyPlanResolution.Failure.Code,
        message: String
    ) -> JourneyPlanResolution.Failure {
        JourneyPlanResolution.Failure(code: code, message: message)
    }

    @MainActor
    private static func direction(
        option: JourneyOption,
        trips: [TrainTrip],
        failures: [(String, JourneyPlanResolution.Failure)]
    ) -> JourneyPlanResolution.Direction {
        let places = endpointPlaces(in: option)
        let successful = trips.enumerated().map { index, trip in
            JourneyPlanResolution.Segment(
                segmentID: "available-\(index)",
                trip: trip,
                failure: nil
            )
        }
        let unavailable = failures.map { segmentID, failure in
            JourneyPlanResolution.Segment(
                segmentID: segmentID,
                trip: nil,
                failure: failure
            )
        }
        return JourneyPlanResolution.Direction(
            fingerprint: option.fingerprint,
            originStationID: places.origin,
            destinationStationID: places.destination,
            departure: option.startTime,
            arrival: option.endTime,
            segments: successful + unavailable
        )
    }

    private static func endpointPlaces(
        in option: JourneyOption
    ) -> (origin: RailIdentifier, destination: RailIdentifier) {
        for segment in option.segments {
            if case let .rail(rail) = segment {
                return (rail.from.place.id, rail.to.place.id)
            }
        }
        preconditionFailure("Journey option fixture requires a rail segment")
    }
}

extension XCTestCase {
    @MainActor
    func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition was not met", file: file, line: line)
    }

    @MainActor
    func makeJourneySearchStore(
        client: any JourneySearching,
        tracker: RecordingJourneyPlanTracker = RecordingJourneyPlanTracker(),
        form: JourneySearchFormState = JourneySearchStoreFixtures.form()
    ) -> JourneySearchStore {
        JourneySearchStore(client: client, planTracker: tracker, form: form)
    }

    @MainActor
    func prepareOneWayJourneyReview(
        client: ScriptedJourneySearchClient,
        tracker: RecordingJourneyPlanTracker = RecordingJourneyPlanTracker(),
        outbound: JourneyOption
    ) async -> JourneySearchStore {
        let store = makeJourneySearchStore(
            client: client,
            tracker: tracker,
            form: JourneySearchStoreFixtures.form(returnEnabled: false)
        )
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        XCTAssertEqual(store.phase, .reviewing)
        return store
    }

    @MainActor
    func makeReviewingJourneyStore(
        outbound requestedOutbound: JourneyOption? = nil,
        returnOption requestedReturn: JourneyOption? = nil
    ) async -> JourneySearchStore {
        let outbound = requestedOutbound ?? journeyOutboundOption()
        let returnOption = requestedReturn ?? journeyReturnOption()
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
            .success(JourneySearchStoreFixtures.page(options: [returnOption])),
        ])
        let store = makeJourneySearchStore(client: client)
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }
        store.selectOutbound(outbound)
        await waitUntil { store.phase == .showingReturn }
        store.selectReturn(returnOption)
        return store
    }

    @MainActor
    func assertJourneySelectionsCleared(
        _ store: JourneySearchStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(store.selectedOutbound, file: file, line: line)
        XCTAssertNil(store.selectedReturn, file: file, line: line)
        XCTAssertNil(store.outboundPage, file: file, line: line)
        XCTAssertNil(store.returnPage, file: file, line: line)
        XCTAssertEqual(store.phase, .editing, file: file, line: line)
    }

    func journeyOutboundOption(
        id: String = "outbound",
        fingerprint: String = "outbound-fingerprint",
        start: Date = JourneySearchStoreFixtures.date("2026-07-24T06:25:00Z"),
        end: Date = JourneySearchStoreFixtures.date("2026-07-24T09:50:00Z"),
        isTrackable: Bool = true,
        untrackableReason: String? = nil
    ) -> JourneyOption {
        JourneySearchStoreFixtures.option(
            id: id,
            fingerprint: fingerprint,
            start: start,
            end: end,
            isTrackable: isTrackable,
            untrackableReason: untrackableReason
        )
    }

    func journeyReturnOption(
        id: String = "return",
        fingerprint: String = "return-fingerprint",
        start: Date = JourneySearchStoreFixtures.date("2026-07-25T06:25:00Z"),
        transferCount: Int = 0,
        isTrackable: Bool = true,
        untrackableReason: String? = nil
    ) -> JourneyOption {
        JourneySearchStoreFixtures.option(
            id: id,
            fingerprint: fingerprint,
            start: start,
            end: start.addingTimeInterval(12_000),
            origin: JourneySearchStoreFixtures.amsterdam,
            destination: JourneySearchStoreFixtures.paris,
            transferCount: transferCount,
            isTrackable: isTrackable,
            untrackableReason: untrackableReason
        )
    }
}

import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneyConsumerEvidenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testClockEndDoesNotClaimArrivalInHeroFactsOrAccessibility() {
        let train = trip()
        let progress = RailJourneyProgress(trip: train, referenceDate: now)
        XCTAssertEqual(progress.phase, .ended)
        XCTAssertEqual(TripObservationLabels.focus(progress), "Destination")
        XCTAssertEqual(TripObservationLabels.arrival(progress), "Timetable arrival")
        let summary = tripAccessibilitySummary(train, referenceDate: now)
        XCTAssertTrue(summary.contains("arrival unconfirmed"))
        XCTAssertFalse(summary.contains("journey ended"))
        XCTAssertFalse(summary.contains("status: Arrived"))
    }

    func testConfirmedArrivalCanSupplyArrivalLabels() {
        let train = trip(arrivalObservedAt: now.addingTimeInterval(-10))
        let progress = RailJourneyProgress(trip: train, referenceDate: now)
        XCTAssertTrue(progress.evidence.isArrivalConfirmed)
        XCTAssertEqual(TripObservationLabels.focus(progress), "Arrived")
        XCTAssertEqual(TripObservationLabels.arrival(progress), "Timetable arrival",
                       "A confirmed arrival must not relabel a scheduled clock as the actual arrival time")
        XCTAssertTrue(tripAccessibilitySummary(train, referenceDate: now).contains("arrival confirmed"))
    }

    func testScheduleOnlyNextStopIsQualified() {
        let train = trip(arrival: now.addingTimeInterval(600))
        let progress = RailJourneyProgress(trip: train, referenceDate: now)
        XCTAssertEqual(progress.phase, .underway)
        XCTAssertEqual(TripObservationLabels.focus(progress), "Timetable next stop")
        XCTAssertTrue(tripAccessibilitySummary(train, referenceDate: now).contains("timetable next stop:"))
    }

    func testFreshDelayedLegRetainsFocusInsteadOfAdvancingToConnectionOrReturn() {
        let train = trip(positionLatitude: 40.25)
        let saved = plan(includesReturn: true, includesConnection: true)
        let stage = JourneyPlanStage(plan: saved, trips: [train], referenceDate: now)
        XCTAssertEqual(stage.directionTitle, "Outbound")
        XCTAssertEqual(stage.focusTrip?.id, train.id)
        XCTAssertEqual(stage.focusSegment?.id, "out")
        XCTAssertEqual(stage.kind, .rail)
        XCTAssertTrue(stage.hasObservedUnfinishedJourney)
        XCTAssertNil(stage.connection)
    }

    func testFreshDelayedPlanRemainsCurrentAndVisibleOnHomeWithoutInventingArrival() {
        let train = trip(positionLatitude: 40.25)
        let saved = plan()
        let list = JourneyPlanListPresentation(plans: [saved], trips: [train], activeTrip: train, at: now)
        XCTAssertEqual(list.currentJourneys(asOf: now).map(\.id), [saved.id])
        XCTAssertTrue(list.pastJourneys(asOf: now).isEmpty)
        XCTAssertEqual(list.journeyPlans.first?.effectiveArrival, saved.outbound.arrival)
        let home = JourneyHomeGuidance.select(plans: [saved], trips: [train], at: now)
        XCTAssertEqual(home?.plan.id, saved.id)
        XCTAssertEqual(home?.isRecentCompletion, false)
    }

    func testStaleOrOffRoutePositionDoesNotHoldThePlanOpen() {
        for train in [trip(positionLatitude: 40.25, positionDate: now.addingTimeInterval(-301)),
                      trip(positionLatitude: 40.25, positionLongitude: -2)] {
            let saved = plan(includesReturn: true)
            let stage = JourneyPlanStage(plan: saved, trips: [train], referenceDate: now)
            XCTAssertEqual(stage.directionTitle, "Return")
            XCTAssertFalse(stage.hasObservedUnfinishedJourney)
        }
    }

    func testVehicleContinuingBeyondSelectedAlightingDoesNotHoldPassengerLegOpen() {
        let train = trip(positionLatitude: 40.75, includesBeyond: true)
        let saved = plan(includesReturn: true)
        let stage = JourneyPlanStage(plan: saved, trips: [train], referenceDate: now)
        XCTAssertEqual(stage.directionTitle, "Return")
        XCTAssertFalse(stage.hasObservedUnfinishedJourney)
        XCTAssertNotNil(RailJourneyEvidence(trip: train, referenceDate: now).observedFocusStopID,
                        "The whole train is still running beyond the selected destination")
    }

    private func place(_ index: Int) -> RailPlace {
        RailPlace(id: station(index).id, kind: .station, displayName: station(index).displayName,
                  context: "", countryCode: "ES", timeZoneIdentifier: "Europe/Madrid",
                  location: station(index).location, eligibleModes: ["highSpeedRail"], attributions: [])
    }

    private func station(_ index: Int) -> Station {
        Station(id: RailIdentifier(region: "eu", source: "transitous", nativeID: "station-\(index)"),
                names: [LocalizedStationName(["Madrid", "Zaragoza", "Barcelona"][index])],
                location: GeoCoordinate(latitude: 40 + Double(index) * 0.5, longitude: -3), countryCode: "ES")
    }

    private func trip(
        arrival: Date? = nil, arrivalObservedAt: Date? = nil, positionLatitude: Double? = nil,
        positionLongitude: Double = -3, positionDate: Date? = nil, includesBeyond: Bool = false
    ) -> TrainTrip {
        let end = arrival ?? now.addingTimeInterval(-600)
        var stops = [
            StopTime(station: station(0), sequence: 1, scheduledDeparture: now.addingTimeInterval(-3_600), isPassed: true),
            StopTime(station: station(1), sequence: 2, scheduledArrival: end,
                     scheduledDeparture: includesBeyond ? end.addingTimeInterval(60) : nil,
                     isPassed: true, arrivalObservedAt: arrivalObservedAt),
        ]
        if includesBeyond {
            stops.append(StopTime(station: station(2), sequence: 3, scheduledArrival: now.addingTimeInterval(600)))
        }
        return TrainTrip(
            id: RailIdentifier(region: "eu", source: "transitous", nativeID: "out"), source: "transitous",
            serviceDate: now, operatorName: "Renfe", product: "AVE", headsign: stops.last!.station.displayName,
            stopTimes: stops,
            positions: positionLatitude.map { [VehiclePosition(
                coordinate: GeoCoordinate(latitude: $0, longitude: positionLongitude), source: .real,
                confidence: 1, asOf: positionDate ?? now
            )] } ?? [],
            capabilities: RealtimeCapabilities(hasPositions: true, hasPlatforms: false,
                                               hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop)
        )
    }

    private func plan(includesReturn: Bool = false, includesConnection: Bool = false) -> TrackedJourneyPlan {
        let trainID = RailIdentifier(region: "eu", source: "transitous", nativeID: "out")
        var segments = [JourneyPlanSegment(
            id: "out", kind: .rail, from: place(0), to: place(1),
            departure: now.addingTimeInterval(-3_600), arrival: now.addingTimeInterval(-600),
            serviceName: "AVE", resolvedTripID: trainID
        )]
        if includesConnection {
            segments.append(JourneyPlanSegment(
                id: "onward", kind: .rail, from: place(1), to: place(2),
                departure: now.addingTimeInterval(-300), arrival: now.addingTimeInterval(-60),
                serviceName: "Onward", unavailableReason: "Not tracked"
            ))
        }
        return TrackedJourneyPlan(
            id: UUID(), createdAt: now.addingTimeInterval(-7_200), origin: place(0), destination: place(1),
            outbound: JourneyPlanDirection(fingerprint: "outbound", departure: segments[0].departure!,
                                            arrival: segments.last!.arrival!, childTripIDs: [trainID], selectedSegments: segments),
            returnDirection: includesReturn ? JourneyPlanDirection(
                fingerprint: "return", departure: now.addingTimeInterval(3_600), arrival: now.addingTimeInterval(7_200),
                childTripIDs: [], selectedSegments: []
            ) : nil,
            preExistingChildTripIDs: []
        )
    }
}

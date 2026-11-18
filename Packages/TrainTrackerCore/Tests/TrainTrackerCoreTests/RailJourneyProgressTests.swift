import Foundation
import Testing
@testable import TrainTrackerCore

@Suite struct RailJourneyProgressTests {
    private let departure = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func phaseChangesAtExactTimeBoundaries() {
        let trip = makeTrip([
            stop("A", sequence: 1, departureMinutes: 0),
            stop("B", sequence: 2, arrivalMinutes: 60),
        ])
        let cases: [(TimeInterval, RailJourneyProgress.Phase, TimeInterval?)] = [
            (-1_801, .upcoming, -1_800),
            (-1_800, .departureSoon, 0),
            (-1, .departureSoon, 0),
            (0, .underway, 3_600),
            (3_599, .underway, 3_600),
            (3_600, .ended, nil),
        ]
        for (offset, phase, nextOffset) in cases {
            let progress = RailJourneyProgress(trip: trip, referenceDate: date(seconds: offset))
            #expect(progress.phase == phase)
            #expect(progress.timingBasis == .scheduled)
            #expect(progress.nextTransitionDate == nextOffset.map { date(seconds: $0) })
            #expect(progress.focusStop?.station.id == (phase == .ended ? nil : id(offset < 0 ? "A" : "B")))
        }
    }

    @Test func selectedSegmentUsesItsOwnBoardingAndAlightingCalls() {
        let trip = makeTrip([
            stop("A", sequence: 1, departureMinutes: -60),
            stop("B", sequence: 2, arrivalMinutes: -5, departureMinutes: 0),
            stop("C", sequence: 3, arrivalMinutes: 30, departureMinutes: 35),
            stop("D", sequence: 4, arrivalMinutes: 60, departureMinutes: 65),
            stop("E", sequence: 5, arrivalMinutes: 120),
        ])
        let progress = RailJourneyProgress(
            trip: trip, referenceDate: date(minutes: -10),
            boardingStationID: id("B"), alightingStationID: id("D")
        )
        #expect(progress.stops.map(\.station.id) == [id("B"), id("C"), id("D")])
        #expect(progress.departureDate == departure)
        #expect(progress.arrivalDate == date(minutes: 60))
        #expect(progress.phase == .departureSoon)
        #expect(progress.focusStop?.station.id == id("B"))
    }

    @Test func providerIndependentStationPlacesMatchUniqueResolvedStopsByLocation() {
        let trip = makeTrip([
            stop("A", sequence: 1, departureMinutes: -60, latitude: 38.80, longitude: -77.06),
            stop("WAS", sequence: 2, arrivalMinutes: -5, departureMinutes: 0, latitude: 38.89699, longitude: -77.006424),
            stop("NYP", sequence: 3, arrivalMinutes: 180, latitude: 40.750328, longitude: -73.99446),
        ])
        let progress = RailJourneyProgress(
            trip: trip,
            referenceDate: date(minutes: -10),
            boardingPlace: place("opaque-was", matching: trip.stopTimes[1].station),
            alightingPlace: place("opaque-nyp", matching: trip.stopTimes[2].station)
        )

        #expect(progress.stops.map(\.station.id) == [id("WAS"), id("NYP")])
        #expect(progress.phase == .departureSoon)
        #expect(progress.focusStop?.station.id == id("WAS"))
    }

    @Test func repeatedLocationCannotSelectAnArbitraryResolvedStop() {
        let trip = makeTrip([
            stop("A", sequence: 1, departureMinutes: 0, latitude: 40, longitude: -74),
            stop("B", sequence: 2, arrivalMinutes: 30, departureMinutes: 35, latitude: 40.5, longitude: -73.5),
            stop("A-again", sequence: 3, arrivalMinutes: 60, latitude: 40, longitude: -74),
        ])
        let progress = RailJourneyProgress(
            trip: trip,
            referenceDate: departure,
            boardingPlace: place("opaque-loop", matching: trip.stopTimes[0].station),
            alightingPlace: place("opaque-destination", matching: trip.stopTimes[1].station)
        )

        #expect(progress.phase == .unavailable)
        #expect(progress.stops.isEmpty)
    }

    @Test func partialSelectionDefaultsOnlyTheUnspecifiedEndpoint() {
        let trip = makeTrip([
            stop("A", sequence: 1, departureMinutes: -60),
            stop("B", sequence: 2, arrivalMinutes: 0, departureMinutes: 5),
            stop("C", sequence: 3, arrivalMinutes: 60),
        ])
        let boarding = RailJourneyProgress(trip: trip, referenceDate: departure, boardingStationID: id("B"))
        let alighting = RailJourneyProgress(trip: trip, referenceDate: departure, alightingStationID: id("B"))
        #expect(boarding.stops.map(\.station.id) == [id("B"), id("C")])
        #expect(boarding.phase == .departureSoon)
        #expect(alighting.stops.map(\.station.id) == [id("A"), id("B")])
        #expect(alighting.phase == .ended)
    }

    @Test func invalidExplicitSelectionsDoNotFallBackToTheFullTrain() {
        let trip = makeTrip([
            stop("A", sequence: 1, departureMinutes: 0),
            stop("B", sequence: 2, arrivalMinutes: 60),
        ])
        let selections: [(RailIdentifier?, RailIdentifier?)] = [
            (id("missing"), nil), (nil, id("missing")),
            (id("B"), id("A")), (id("A"), id("A")),
        ]
        for (boarding, alighting) in selections {
            let progress = RailJourneyProgress(
                trip: trip, referenceDate: departure,
                boardingStationID: boarding, alightingStationID: alighting
            )
            #expect(progress.phase == .unavailable)
            #expect(progress.stops.isEmpty)
            #expect(progress.focusStop == nil)
            #expect(progress.departureDate == nil)
            #expect(progress.arrivalDate == nil)
            #expect(progress.nextTransitionDate == nil)
        }
    }

    @Test func repeatedSelectedStationIsAmbiguous() {
        let trip = makeTrip([
            stop("A", sequence: 1, departureMinutes: 0),
            stop("B", sequence: 2, arrivalMinutes: 30, departureMinutes: 35),
            stop("A", sequence: 3, arrivalMinutes: 60),
        ])
        let selected = RailJourneyProgress(trip: trip, referenceDate: departure, boardingStationID: id("A"))
        let wholeTrain = RailJourneyProgress(trip: trip, referenceDate: departure)
        #expect(selected.phase == .unavailable)
        #expect(selected.stops.isEmpty)
        #expect(wholeTrain.phase == .underway)
        #expect(wholeTrain.stops.count == 3)
    }

    @Test func estimatesShiftDepartureWindowAndAreNotFreshnessClaims() {
        let trip = makeTrip([
            stop("A", sequence: 1, departureMinutes: 0, expectedDepartureMinutes: 45),
            stop("B", sequence: 2, arrivalMinutes: 60, expectedArrivalMinutes: 105),
        ])
        let beforeWindow = RailJourneyProgress(trip: trip, referenceDate: departure)
        let pastEstimate = RailJourneyProgress(trip: trip, referenceDate: date(minutes: 180))
        #expect(beforeWindow.phase == .upcoming)
        #expect(beforeWindow.timingBasis == .estimated)
        #expect(beforeWindow.nextTransitionDate == date(minutes: 15))
        #expect(beforeWindow.departureDate == date(minutes: 45))
        #expect(beforeWindow.arrivalDate == date(minutes: 105))
        #expect(pastEstimate.phase == .ended)
        #expect(pastEstimate.timingBasis == .estimated)
    }

    @Test func timingBasisMatchesTheEventDrivingThePhase() {
        let trip = makeTrip([
            stop("A", sequence: 1, departureMinutes: 0),
            stop("B", sequence: 2, arrivalMinutes: 60, expectedArrivalMinutes: 75),
        ])
        #expect(RailJourneyProgress(trip: trip, referenceDate: date(minutes: -5)).timingBasis == .scheduled)
        #expect(RailJourneyProgress(trip: trip, referenceDate: date(minutes: 20)).timingBasis == .estimated)
        #expect(RailJourneyProgress(trip: trip, referenceDate: date(minutes: 75)).timingBasis == .estimated)
    }

    @Test func passageFlagsNeverDeterminePhaseOrFocus() {
        let trip = makeTrip([
            stop("A", sequence: 1, departureMinutes: 0, passed: true),
            stop("B", sequence: 2, arrivalMinutes: 60, passed: true),
        ])
        let future = RailJourneyProgress(trip: trip, referenceDate: date(minutes: -60))
        let underway = RailJourneyProgress(trip: trip, referenceDate: date(minutes: 20))
        #expect(!trip.isComplete) // Legacy timetable-derived flags are not arrival evidence.
        #expect(future.phase == .upcoming)
        #expect(future.focusStop?.station.id == id("A"))
        #expect(underway.phase == .underway)
        #expect(underway.focusStop?.station.id == id("B"))
    }

    @Test func focusSkipsCancelledCallsAndStaysDuringDwell() {
        let trip = makeTrip([
            stop("A", sequence: 1, departureMinutes: 0),
            stop("B", sequence: 2, arrivalMinutes: 10, departureMinutes: 15, cancelled: true),
            stop("C", sequence: 3, arrivalMinutes: 20, departureMinutes: 25),
            stop("D", sequence: 4, arrivalMinutes: 60),
        ])
        for minute in [5.0, 20.0, 24.0] {
            let progress = RailJourneyProgress(trip: trip, referenceDate: date(minutes: minute))
            #expect(progress.focusStop?.station.id == id("C"))
            #expect(progress.nextTransitionDate == date(minutes: 25))
        }
        let afterDwell = RailJourneyProgress(trip: trip, referenceDate: date(minutes: 25))
        #expect(afterDwell.focusStop?.station.id == id("D"))
        #expect(afterDwell.nextTransitionDate == date(minutes: 60))
        #expect(!afterDwell.isCancelled)
    }

    @Test func cancelledBoardingDoesNotSuggestBoardingElsewhere() {
        let trip = makeTrip([
            stop("A", sequence: 1, departureMinutes: 0, cancelled: true),
            stop("B", sequence: 2, arrivalMinutes: 60),
        ])
        let progress = RailJourneyProgress(trip: trip, referenceDate: date(minutes: -5))
        #expect(progress.phase == .departureSoon)
        #expect(progress.focusStop == nil)
        #expect(!progress.isCancelled)
    }

    @Test func cancelledSegmentHasNoActionableFocusOrTransition() {
        let trip = makeTrip([
            stop("A", sequence: 1, departureMinutes: 0, cancelled: true),
            stop("B", sequence: 2, arrivalMinutes: 60, cancelled: true),
        ])
        let progress = RailJourneyProgress(trip: trip, referenceDate: date(minutes: -5))
        #expect(progress.isCancelled)
        #expect(progress.phase == .unavailable)
        #expect(progress.focusStop == nil)
        #expect(progress.nextTransitionDate == nil)
        #expect(progress.stops.count == 2)
        #expect(progress.departureDate == departure)
    }

    @Test func missingOrContradictoryTimingIsUnavailable() {
        let cases = [
            [],
            [stop("A", sequence: 1, departureMinutes: 0)],
            [stop("A", sequence: 1), stop("B", sequence: 2, arrivalMinutes: 60)],
            [stop("A", sequence: 1, departureMinutes: 0), stop("B", sequence: 2)],
            [stop("A", sequence: 1, departureMinutes: 0, expectedDepartureMinutes: 90),
             stop("B", sequence: 2, arrivalMinutes: 60)],
        ]
        for stops in cases {
            let progress = RailJourneyProgress(trip: makeTrip(stops), referenceDate: departure)
            #expect(progress.phase == .unavailable)
            #expect(progress.focusStop == nil)
            #expect(progress.nextTransitionDate == nil)
            #expect(!progress.isCancelled)
        }
    }

    private func date(seconds: TimeInterval) -> Date { departure.addingTimeInterval(seconds) }
    private func date(minutes: Double) -> Date { date(seconds: minutes * 60) }
    private func id(_ name: String) -> RailIdentifier { RailIdentifier(rawValue: "eu:test:\(name)") }

    private func stop(
        _ name: String, sequence: Int,
        arrivalMinutes: Double? = nil, departureMinutes: Double? = nil,
        expectedArrivalMinutes: Double? = nil, expectedDepartureMinutes: Double? = nil,
        cancelled: Bool = false, passed: Bool = false,
        latitude: Double = 0, longitude: Double = 0
    ) -> StopTime {
        StopTime(
            station: Station(
                id: id(name), names: [LocalizedStationName(name)],
                location: GeoCoordinate(latitude: latitude, longitude: longitude), countryCode: "GB"
            ),
            sequence: sequence,
            scheduledArrival: arrivalMinutes.map { date(minutes: $0) },
            scheduledDeparture: departureMinutes.map { date(minutes: $0) },
            expectedArrival: expectedArrivalMinutes.map { date(minutes: $0) },
            expectedDeparture: expectedDepartureMinutes.map { date(minutes: $0) },
            isCancelled: cancelled, isPassed: passed
        )
    }

    private func place(_ name: String, matching station: Station) -> RailPlace {
        RailPlace(
            id: id(name), kind: .station, displayName: station.displayName,
            context: "United Kingdom", countryCode: station.countryCode,
            timeZoneIdentifier: "Europe/London", location: station.location,
            eligibleModes: ["regionalRail"], attributions: []
        )
    }

    private func makeTrip(_ stops: [StopTime]) -> TrainTrip {
        TrainTrip(
            id: id("train"), source: "test", serviceDate: departure,
            operatorName: "Rail", product: "Regional", headsign: "Destination", stopTimes: stops,
            capabilities: RealtimeCapabilities(
                hasPositions: false, hasPlatforms: false, hasRealtimeDelays: true,
                hasAlerts: false, granularity: .perStop
            )
        )
    }
}

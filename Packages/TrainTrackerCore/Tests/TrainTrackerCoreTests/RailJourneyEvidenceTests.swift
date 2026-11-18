import Foundation
import Testing
@testable import TrainTrackerCore

@Suite struct RailJourneyEvidenceTests {
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    @Test func elapsedSpanishTimetableNeverConfirmsPassageOrArrival() {
        let value = trip(stops: stops(legacyPassed: true))
        let progress = RailJourneyProgress(trip: value, referenceDate: now)
        #expect(progress.phase == .ended) // Explicitly the timetable window, not an arrival claim.
        #expect(progress.evidence.basis == .unconfirmed)
        #expect(progress.evidence.confirmedPassedStopIDs.isEmpty)
        #expect(!progress.evidence.isArrivalConfirmed)
        #expect(!value.isComplete)
    }

    @Test func freshTrainGPSKeepsDelayedTrainBeforeItsNextStation() {
        let value = trip(positions: [position(longitude: -3.98)])
        let progress = RailJourneyProgress(trip: value, referenceDate: now)
        #expect(progress.phase == .underway)
        #expect(progress.focusStop?.id == value.stopTimes[1].id)
        #expect(progress.evidence.basis == .vehiclePosition)
        #expect(progress.evidence.confirmedPassedStopIDs == [value.stopTimes[0].id])
        #expect(!progress.evidence.isArrivalConfirmed)
    }

    @Test func staleOrInferredPositionCannotConfirmProgress() {
        for fix in [position(age: 301), position(source: .inferred), position(age: -121),
                    position(confidence: 0), position(longitude: 200)] {
            let progress = RailJourneyProgress(trip: trip(positions: [fix]), referenceDate: now)
            #expect(progress.evidence.position == nil)
            #expect(progress.evidence.observedFocusStopID == nil)
            #expect(!progress.evidence.isArrivalConfirmed)
        }
        let old = trip(positions: [position(age: 600)])
        #expect(RailJourneyEvidence.freshPosition(in: old, at: now) == nil)
        #expect(RailJourneyEvidence.latestRealPosition(in: old, at: now, maximumAge: 7_200) != nil)
    }

    @Test func GPSAtTerminalDoesNotProveArrival() {
        let value = trip(positions: [position(longitude: -3.8)])
        let progress = RailJourneyProgress(trip: value, referenceDate: now)
        #expect(progress.phase == .underway)
        #expect(progress.focusStop?.id == value.stopTimes.last?.id)
        #expect(!progress.evidence.isArrivalConfirmed)
    }

    @Test func GPSBeyondSelectedIntermediateDestinationConfirmsPassage() {
        let value = trip(positions: [position(longitude: -3.85)])
        let progress = RailJourneyProgress(trip: value, referenceDate: now,
            boardingStationID: value.stopTimes[0].station.id, alightingStationID: value.stopTimes[1].station.id)
        #expect(progress.evidence.isArrivalConfirmed)
        #expect(progress.phase == .ended)
    }

    @Test func OffRouteAndAmbiguousLoopPositionsDoNotEstablishPassage() {
        let offRoute = trip(positions: [position(longitude: -2)])
        #expect(RailJourneyEvidence(trip: offRoute, referenceDate: now).basis == .unconfirmed)
        var loopStops = stops()
        loopStops[2] = stop("C", sequence: 3, longitude: -4, minutes: -10)
        let loop = trip(stops: loopStops, positions: [position(longitude: -3.98)])
        #expect(RailJourneyEvidence(trip: loop, referenceDate: now).basis == .unconfirmed)
    }

    @Test func explicitArrivalConfirmsTerminalButIntermediateArrivalHoldsDwell() {
        var calls = stops()
        calls[1] = stop("B", sequence: 2, longitude: -3.9, minutes: -30, arrivalObservedAt: now)
        var progress = RailJourneyProgress(trip: trip(stops: calls), referenceDate: now)
        #expect(progress.focusStop?.id == calls[1].id)
        #expect(progress.phase == .underway)
        #expect(!progress.evidence.confirmedPassedStopIDs.contains(calls[1].id))
        #expect(!progress.evidence.isArrivalConfirmed)
        calls[2] = stop("C", sequence: 3, longitude: -3.8, minutes: -10, arrivalObservedAt: now)
        let arrived = trip(stops: calls, positions: [position(longitude: -3.8, age: 10)])
        progress = RailJourneyProgress(trip: arrived, referenceDate: now)
        #expect(progress.evidence.isArrivalConfirmed)
        #expect(progress.phase == .ended)
        #expect(arrived.isComplete)
    }

    @Test func futureReportsAndUnstampedLegacyFlagsAreNotConfirmed() throws {
        let future = stop("A", sequence: 1, longitude: -4, minutes: -60,
                          passed: true, passageObservedAt: now.addingTimeInterval(121))
        #expect(!future.hasConfirmedPassage(at: now))
        let original = stop("A", sequence: 1, longitude: -4, minutes: -60, passed: true)
        let decoded = try JSONDecoder().decode(StopTime.self, from: JSONEncoder().encode(original))
        #expect(decoded.passageObservedAt == nil)
        #expect(!decoded.hasConfirmedPassage(at: now))
    }

    @Test func newerTerminalGPSPreservesActualArrivalButAnEarlierRouteFixContradictsIt() {
        var calls = stops()
        calls[2] = stop("C", sequence: 3, longitude: -3.8, minutes: -10,
                        arrivalObservedAt: now.addingTimeInterval(-120))
        for longitude in [-3.8, -3.803] {
            let evidence = RailJourneyEvidence(trip: trip(stops: calls,
                positions: [position(longitude: longitude)]), referenceDate: now)
            #expect(evidence.isArrivalConfirmed)
        }
        let before = RailJourneyEvidence(trip: trip(stops: calls,
            positions: [position(longitude: -3.82)]), referenceDate: now)
        #expect(!before.isArrivalConfirmed)
        calls[2] = stop("C", sequence: 3, longitude: -3.8, minutes: -10, passed: true,
                        passageObservedAt: now.addingTimeInterval(121),
                        arrivalObservedAt: now.addingTimeInterval(-120))
        let invalidNewReport = RailJourneyEvidence(trip: trip(stops: calls,
            positions: [position(longitude: -3.82)]), referenceDate: now)
        #expect(!invalidNewReport.isArrivalConfirmed)
    }

    @Test func olderReportedPassageRemainsHistoryWithoutFixingCurrentFocusForever() {
        var calls = stops()
        calls[0] = stop("A", sequence: 1, longitude: -4, minutes: -60, passed: true,
                        passageObservedAt: now.addingTimeInterval(-3_600))
        let progress = RailJourneyProgress(trip: trip(stops: calls), referenceDate: now)
        #expect(progress.evidence.confirmedPassedStopIDs == [calls[0].id])
        #expect(progress.evidence.observedFocusStopID == nil)
        #expect(!progress.evidence.isArrivalConfirmed)
    }

    private func stops(legacyPassed: Bool = false) -> [StopTime] {
        [stop("A", sequence: 1, longitude: -4, minutes: -60, passed: legacyPassed),
         stop("B", sequence: 2, longitude: -3.9, minutes: -30, passed: legacyPassed),
         stop("C", sequence: 3, longitude: -3.8, minutes: -10, passed: legacyPassed)]
    }

    private func stop(_ name: String, sequence: Int, longitude: Double, minutes: Double,
                      passed: Bool = false, passageObservedAt: Date? = nil, arrivalObservedAt: Date? = nil) -> StopTime {
        StopTime(station: Station(id: RailIdentifier(rawValue: "eu:transitous:\(name)"),
            names: [LocalizedStationName(name)], location: GeoCoordinate(latitude: 40, longitude: longitude), countryCode: "ES"),
            sequence: sequence, scheduledDeparture: now.addingTimeInterval(minutes * 60),
            expectedDeparture: now.addingTimeInterval(minutes * 60), isPassed: passed,
            passageObservedAt: passageObservedAt, arrivalObservedAt: arrivalObservedAt)
    }

    private func position(longitude: Double = -3.98, age: Double = 0,
                          source: PositionSource = .real, confidence: Double = 1) -> VehiclePosition {
        VehiclePosition(coordinate: GeoCoordinate(latitude: 40, longitude: longitude),
                        source: source, confidence: confidence, asOf: now.addingTimeInterval(-age))
    }

    private func trip(stops: [StopTime]? = nil, positions: [VehiclePosition] = []) -> TrainTrip {
        TrainTrip(id: RailIdentifier(rawValue: "eu:transitous:es-renfe-123"), source: "transitous",
            serviceDate: now, operatorName: "Renfe", product: "AVE 123", headsign: "C",
            stopTimes: stops ?? self.stops(), positions: positions,
            capabilities: RealtimeCapabilities(hasPositions: true, hasPlatforms: true,
                hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop))
    }
}

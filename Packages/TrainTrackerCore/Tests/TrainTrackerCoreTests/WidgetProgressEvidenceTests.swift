import Foundation
import Testing
@testable import TrainTrackerCore

@Suite struct WidgetProgressEvidenceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func elapsedTimetableNeverCreatesArrivalCheckmarkOrFullGauge() {
        let train = savedTrain()
        let presentation = WidgetTrainPresentation(train: train, at: now)
        #expect(presentation.phase != .arrived)
        #expect(presentation.statusText == "Arrival unconfirmed")
        #expect(presentation.legProgress == 0)
        #expect(presentation.inlineText == "Arrival unconfirmed")
        let expired = now.addingTimeInterval(3 * 3_600)
        let display = WidgetDisplay(snapshot: WidgetTripSnapshot(generatedAt: now, trains: [train]), at: expired)
        #expect(display == .train(train, following: nil), "technical retention cannot select the ended layout")
    }

    @Test func freshFocusAtBoardingSurvivesElapsedArrivalClock() {
        let train = savedTrain(evidence: WidgetProgressEvidence(observedFocusStopID: "origin#1", observedAt: now))
        let presentation = WidgetTrainPresentation(train: train, at: now)
        #expect(train.observedFocusIndex(at: now) == 0)
        #expect(presentation.phase == .upcoming(departureSoon: true))
        #expect(presentation.anchor == .departs)
        #expect(presentation.nextStop == nil)
        #expect(presentation.legProgress == 0)
        #expect(train.observedFocusIndex(at: now.addingTimeInterval(301)) == nil)
    }

    @Test func freshGPSBehindTimetableKeepsObservedIntermediateFocus() throws {
        let position = VehiclePosition(coordinate: GeoCoordinate(latitude: 39.7, longitude: -77),
                                       source: .real, confidence: 1, asOf: now.addingTimeInterval(-60))
        let train = try #require(WidgetTripSnapshot.Train(trip: sourceTrip(position: position), referenceDate: now))
        let presentation = WidgetTrainPresentation(train: train, at: now)
        #expect(train.observedFocusIndex(at: now) == 1)
        #expect(presentation.phase == .underway(nextStopIndex: 1))
        #expect(presentation.nextStop?.name == "Middle")
        #expect(presentation.nextStopLabel == "Next stop")
        #expect(presentation.status != .arrived)
        #expect(presentation.legProgress < 1)
        #expect(presentation.legProgress == 0, "a conservative gauge counts confirmed calls, not elapsed time")
    }

    @Test func oldArchiveWithoutProgressOrStopIDsDecodesAsUnconfirmed() throws {
        let original = WidgetTripSnapshot(generatedAt: now, trains: [savedTrain(evidence:
            WidgetProgressEvidence(arrivalConfirmedAt: now, reportedArrivalAt: now))])
        let encoded = try JSONEncoder().encode(original)
        var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var trains = try #require(payload["trains"] as? [[String: Any]])
        trains[0].removeValue(forKey: "progressEvidence")
        var stops = try #require(trains[0]["stops"] as? [[String: Any]])
        for index in stops.indices { stops[index].removeValue(forKey: "id") }
        trains[0]["stops"] = stops
        payload["trains"] = trains
        let restored = try JSONDecoder().decode(WidgetTripSnapshot.self,
            from: JSONSerialization.data(withJSONObject: payload))
        let train = try #require(restored.trains.first)
        #expect(train.progressEvidence == nil)
        #expect(train.stops.allSatisfy { $0.id == nil })
        #expect(!train.confirmedArrival(at: now))
        #expect(WidgetTrainPresentation(train: train, at: now).legProgress == 0)
        #expect(WidgetTrainPresentation(train: train, at: now).statusText == "Arrival unconfirmed")
    }

    @Test func explicitLateArrivalKeepsItsSourceObservationGrace() throws {
        let reportedAt = now.addingTimeInterval(-5 * 60)
        let train = try #require(WidgetTripSnapshot.Train(
            trip: sourceTrip(arrivalObservedAt: reportedAt), referenceDate: now))
        let presentation = WidgetTrainPresentation(train: train, at: now)
        #expect(presentation.phase == .arrived)
        #expect(presentation.legProgress == 1)
        #expect(train.progressEvidence?.reportedArrivalAt == reportedAt)
        #expect(WidgetTrainPhase.finishDate(train, at: now) == reportedAt.addingTimeInterval(30 * 60))
        #expect(!WidgetTrainPhase.isFinished(train, at: now))
        #expect(WidgetTrainPhase.isFinished(train, at: now.addingTimeInterval(25 * 60)))
    }

    @Test func invalidFutureOrUndatedEvidenceCannotAdvanceProgressOrRetention() {
        for bad in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity),
                    now.addingTimeInterval(121)] {
            let evidence = WidgetProgressEvidence(confirmedPassedStopIDs: ["middle#2", "destination#3"],
                arrivalConfirmedAt: bad, observedFocusStopID: "destination#3", observedAt: bad, reportedArrivalAt: bad)
            let train = savedTrain(evidence: evidence)
            #expect(!train.confirmedArrival(at: now))
            #expect(train.observedFocusIndex(at: now) == nil)
            #expect(train.confirmedProgress(at: now) == 0)
            #expect(WidgetTrainPhase.finishDate(train, at: now) == now.addingTimeInterval(110 * 60))
        }
        let undated = savedTrain(evidence: WidgetProgressEvidence(confirmedPassedStopIDs: ["middle#2"]))
        #expect(undated.confirmedProgress(at: now) == 0)
        let invalidTime = WidgetTripSnapshot.Stop(name: "Invalid", scheduledArrival: Date(timeIntervalSince1970: .infinity))
        #expect(invalidTime.arrival == nil)
    }

    @Test func GPSOnlyConfirmationDoesNotRestartArrivalGraceOnEveryNewFix() {
        let first = savedTrain(evidence: WidgetProgressEvidence(arrivalConfirmedAt: now, observedAt: now))
        let later = savedTrain(evidence: WidgetProgressEvidence(arrivalConfirmedAt: now.addingTimeInterval(60),
                                                              observedAt: now.addingTimeInterval(60)))
        #expect(WidgetTrainPhase.finishDate(first, at: now) == now.addingTimeInterval(20 * 60))
        #expect(WidgetTrainPhase.finishDate(later, at: now.addingTimeInterval(60))
                == WidgetTrainPhase.finishDate(first, at: now))
    }

    @Test func builderUsesValidArrivalProofWhenAnotherTimestampIsMalformedFuture() throws {
        let report = now.addingTimeInterval(-60)
        let train = try #require(WidgetTripSnapshot.Train(
            trip: sourceTrip(arrivalObservedAt: now.addingTimeInterval(86_400), passageObservedAt: report),
            referenceDate: now))
        #expect(train.confirmedArrival(at: now))
        #expect(train.progressEvidence?.arrivalConfirmedAt == report)
        #expect(train.progressEvidence?.reportedArrivalAt == report)
    }

    private func savedTrain(evidence: WidgetProgressEvidence? = nil) -> WidgetTripSnapshot.Train {
        WidgetTripSnapshot.Train(id: "train", serviceName: "Amtrak 171", stops: [
            .init(name: "Origin", id: "origin#1", scheduledDeparture: now.addingTimeInterval(-60 * 60)),
            .init(name: "Middle", id: "middle#2", scheduledArrival: now.addingTimeInterval(-30 * 60),
                  scheduledDeparture: now.addingTimeInterval(-28 * 60)),
            .init(name: "Destination", id: "destination#3", scheduledArrival: now.addingTimeInterval(-10 * 60))
        ], progressEvidence: evidence)
    }

    private func sourceTrip(position: VehiclePosition? = nil, arrivalObservedAt: Date? = nil,
                            passageObservedAt: Date? = nil) -> TrainTrip {
        func station(_ name: String, _ latitude: Double) -> Station {
            Station(id: RailIdentifier(rawValue: "us:amtraker:\(name)"), names: [LocalizedStationName(name)],
                    location: GeoCoordinate(latitude: latitude, longitude: -77), countryCode: "US")
        }
        return TrainTrip(id: RailIdentifier(rawValue: "us:amtraker:171-13"), source: "amtraker", serviceDate: now,
            operatorName: "Amtrak", product: "171", headsign: "Destination", stopTimes: [
                StopTime(station: station("Origin", 40), sequence: 1, scheduledDeparture: now.addingTimeInterval(-60 * 60)),
                StopTime(station: station("Middle", 39), sequence: 2, scheduledArrival: now.addingTimeInterval(-30 * 60),
                         scheduledDeparture: now.addingTimeInterval(-28 * 60)),
                StopTime(station: station("Destination", 38), sequence: 3, scheduledArrival: now.addingTimeInterval(-10 * 60),
                         isPassed: passageObservedAt != nil, passageObservedAt: passageObservedAt,
                         arrivalObservedAt: arrivalObservedAt)
            ], positions: position.map { [$0] } ?? [],
            capabilities: RealtimeCapabilities(hasPositions: position != nil, hasPlatforms: false,
                hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop))
    }
}

import Foundation
import TrainTrackerCore

/// A complete, boardable itinerary from the searched page. A reported departure is still an estimate.
struct JourneyRecoveryOption: Equatable {
    let option: JourneyOption
    let firstTrain: RailJourneySegment
    let departure: Date
    let generatedAt: Date
    let expiresAt: Date

    var service: String { JourneySegmentPresentation.make(from: .rail(firstTrain)).title }
    var estimated: Bool { firstTrain.from.expectedDeparture != nil }

    static func next(in page: JourneySearchPage, request: JourneyRecoveryRequest,
                     at date: Date) -> Self? {
        guard page.expiresAt > date else { return nil }
        return page.options.compactMap { option -> Self? in
            guard !option.trackingToken.isEmpty, !option.fingerprint.isEmpty,
                  let first = itinerary(option, request: request, at: date),
                  let departure = first.from.expectedDeparture ?? first.from.scheduledDeparture else { return nil }
            return Self(option: option, firstTrain: first, departure: departure,
                        generatedAt: page.generatedAt, expiresAt: page.expiresAt)
        }.min { ($0.departure, $0.option.endTime, $0.option.id) < ($1.departure, $1.option.endTime, $1.option.id) }
    }

    /// Run the same station, timing, cancellation and walk checks against the resolved snapshots
    /// before saving. The planning token may still be valid even after a train is cancelled.
    func stillUsable(_ resolution: JourneyPlanResolution, request: JourneyRecoveryRequest, at date: Date) -> Bool {
        guard expiryAndDirectionAreValid(resolution, date: date),
              let direction = resolution.directions.first else { return false }
        let rows = Dictionary(grouping: direction.segments, by: \.segmentID)
        let railCount = option.segments.filter { if case .rail = $0 { true } else { false } }.count
        guard direction.segments.count == railCount else { return false }
        return Self.itinerary(option, request: request, at: date) { rail in
            guard let matches = rows[rail.id], matches.count == 1, let found = matches.first,
                  found.failure == nil, let trip = found.trip, trip.id != request.original.resolvedTripID,
                  !trip.isCancelled else { return nil }
            let progress = RailJourneyProgress(trip: trip, referenceDate: date,
                                              boardingPlace: rail.from.place, alightingPlace: rail.to.place)
            guard let first = progress.stops.first, let last = progress.stops.last, !first.isCancelled,
                  !last.isCancelled, !first.hasConfirmedPassage(at: date),
                  let departure = first.expectedDeparture ?? first.scheduledDeparture,
                  let arrival = last.expectedArrival ?? last.scheduledArrival else { return nil }
            if rail.id == firstTrain.id, abs(departure.timeIntervalSince(self.departure)) >= 60 { return nil }
            return (departure, arrival)
        } != nil
    }

    private func expiryAndDirectionAreValid(_ resolution: JourneyPlanResolution, date: Date) -> Bool {
        guard expiresAt > date, resolution.directions.count == 1, let direction = resolution.directions.first,
              direction.fingerprint == option.fingerprint else { return false }
        let finalRail = option.segments.reversed().compactMap { segment -> RailJourneySegment? in
            guard case let .rail(rail) = segment else { return nil }
            return rail
        }.first
        return direction.originStationID == firstTrain.from.place.id && direction.destinationStationID == finalRail?.to.place.id
    }

    private static func itinerary(
        _ option: JourneyOption, request: JourneyRecoveryRequest, at date: Date,
        timing: (RailJourneySegment) -> (Date, Date)? = { rail in
            guard let departure = rail.from.expectedDeparture ?? rail.from.scheduledDeparture,
                  let arrival = rail.to.expectedArrival ?? rail.to.scheduledArrival else { return nil }
            return (departure, arrival)
        }
    ) -> RailJourneySegment? {
        var station = request.origin
        var ready = max(request.readyAt, date)
        var firstTrain: RailJourneySegment?
        var lastArrival: Date?
        var walkDuration: TimeInterval = 0
        for segment in option.segments {
            switch segment {
            case .walk(let walk):
                guard JourneyTransferStation.matches(walk.from, station), walk.duration.isFinite,
                      walk.duration >= 0 else { return nil }
                station = walk.to
                ready.addTimeInterval(walk.duration)
                walkDuration += walk.duration
            case .rail(let rail):
                if let lastArrival {
                    guard walkDuration.isFinite else { return nil }
                    let allowance = JourneyPlanStage.Connection.planningAllowance(walkingSeconds: walkDuration)
                    ready = lastArrival.addingTimeInterval(allowance)
                }
                guard JourneyTransferStation.matches(rail.from.place, station), rail.isTrackable, !rail.isCancelled,
                      !rail.from.isCancelled, !rail.to.isCancelled,
                      let (departure, arrival) = timing(rail), departure >= ready, departure > date,
                      arrival > departure else { return nil }
                if firstTrain == nil {
                    guard !isOriginal(rail, request: request) else { return nil }
                    firstTrain = rail
                }
                station = rail.to.place
                ready = arrival
                lastArrival = arrival
                walkDuration = 0
            }
        }
        return JourneyTransferStation.matches(station, request.destination) ? firstTrain : nil
    }

    private static func isOriginal(_ rail: RailJourneySegment, request: JourneyRecoveryRequest) -> Bool {
        if let id = rail.tripID, id == request.original.resolvedTripID { return true }
        // Two adapters can identify the same run differently. Exclude the booked station call
        // when its timetable time and service label match even across that boundary.
        guard let planned = request.original.departure, let candidate = rail.from.scheduledDeparture,
              abs(planned.timeIntervalSince(candidate)) < 60, let booked = request.original.serviceName else { return false }
        let productWithNumber = [Optional(rail.product), rail.trainNumber].compactMap { $0 }.joined(separator: " ")
        let names: [String?] = [rail.trainName, rail.product, productWithNumber]
        return names.compactMap { $0 }.contains { $0.caseInsensitiveCompare(booked) == .orderedSame }
    }
}

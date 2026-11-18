import Foundation

/// Observed progress survives the widget/Watch handoff. Missing fields in older snapshots
/// mean unknown progress; the passing clock can never create new arrival evidence.
public struct WidgetProgressEvidence: Codable, Equatable, Sendable {
    public let confirmedPassedStopIDs: [String]
    public let arrivalConfirmedAt: Date?
    /// An explicit provider report, retained separately from GPS-only confirmation.
    /// This remains an observation timestamp, not automatically the arrival event time.
    public let reportedArrivalAt: Date?
    public let observedFocusStopID: String?
    public let observedAt: Date?

    public init(confirmedPassedStopIDs: [String] = [], arrivalConfirmedAt: Date? = nil,
                observedFocusStopID: String? = nil, observedAt: Date? = nil,
                reportedArrivalAt: Date? = nil) {
        self.confirmedPassedStopIDs = Array(Set(confirmedPassedStopIDs)).sorted()
        self.arrivalConfirmedAt = arrivalConfirmedAt
        self.reportedArrivalAt = reportedArrivalAt
        self.observedFocusStopID = observedFocusStopID
        self.observedAt = observedAt
    }

    init(progress: RailJourneyProgress, at date: Date) {
        let evidence = progress.evidence
        let observations = progress.stops.filter { !$0.isCancelled }.flatMap { stop in
            [stop.arrivalObservedAt, stop.isPassed ? stop.passageObservedAt : nil]
        }.compactMap { $0 }.filter { Self.valid($0, at: date) }
        let stopObservation = observations.max()
        let observation = evidence.basis == .reportedPassage
            ? stopObservation : evidence.position?.asOf ?? stopObservation
        let arrival = progress.stops.last.flatMap { stop in
            [stop.arrivalObservedAt, stop.isPassed ? stop.passageObservedAt : nil]
                .compactMap { $0 }.filter { Self.valid($0, at: date) }.max()
        }
        self.init(confirmedPassedStopIDs: Array(evidence.confirmedPassedStopIDs),
                  arrivalConfirmedAt: evidence.isArrivalConfirmed ? (arrival ?? observation) : nil,
                  observedFocusStopID: evidence.observedFocusStopID, observedAt: observation,
                  reportedArrivalAt: evidence.isArrivalConfirmed ? arrival : nil)
    }

    /// Historical observations remain proof, but malformed or future data is not evidence.
    public func validObservation(at date: Date) -> Date? {
        observedAt.flatMap { Self.valid($0, at: date) ? $0 : nil }
    }

    public func validReportedArrival(at date: Date) -> Date? {
        reportedArrivalAt.flatMap { Self.valid($0, at: date) ? $0 : nil }
    }

    private static func valid(_ observation: Date, at date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && observation.timeIntervalSinceReferenceDate.isFinite
            && observation <= date.addingTimeInterval(120)
    }

    public func confirmsArrival(at date: Date) -> Bool {
        guard let arrivalConfirmedAt else { return false }
        return Self.valid(arrivalConfirmedAt, at: date)
    }

    public func hasFreshFocus(at date: Date) -> Bool {
        guard observedFocusStopID != nil, let observedAt = validObservation(at: date) else { return false }
        let age = date.timeIntervalSince(observedAt)
        return age >= -120 && age <= 300
    }
}

public extension WidgetTripSnapshot.Train {
    func confirmedArrival(at date: Date) -> Bool { progressEvidence?.confirmsArrival(at: date) == true }

    func observedFocusIndex(at date: Date) -> Int? {
        guard let evidence = progressEvidence, evidence.hasFreshFocus(at: date),
              let id = evidence.observedFocusStopID else { return nil }
        let matches = stops.indices.filter { stops[$0].id == id }
        return matches.count == 1 ? matches.first : nil
    }

    /// A conservative confirmed fraction, never a timetable interpolation or a claim of arrival.
    func confirmedProgress(at date: Date) -> Double {
        if confirmedArrival(at: date) { return 1 }
        guard stops.count >= 2, let evidence = progressEvidence,
              evidence.validObservation(at: date) != nil else { return 0 }
        let confirmed = Set(evidence.confirmedPassedStopIDs)
        let uniqueIDs = Dictionary(grouping: stops.compactMap(\.id), by: { $0 }).filter { $0.value.count == 1 }
        let index = stops.indices.last {
            stops[$0].id.map { confirmed.contains($0) && uniqueIDs[$0] != nil } == true
        } ?? 0
        return min(0.99, Double(index) / Double(stops.count - 1))
    }
}

import Foundation
import Observation
import TrainTrackerCore

/// One import review: ask only for missing details, search once with disclosed route/time
/// parameters, then hand a unique validated journey to the existing Track Journey confirmation.
/// Nothing here saves a journey; `JourneySearchStore` keeps every resolution and subset gate.
@MainActor
@Observable
final class SmartJourneyReviewStore {
    enum Field: String, CaseIterable, Identifiable, Hashable, Sendable {
        case origin, destination, date, time
        var id: String { rawValue }
    }

    enum Notice: Equatable, Sendable {
        case missingDetails
        case pastDeparture
        case invalidLocalTime
        case stationNotFound(origin: Bool, destination: Bool)
        case lookupFailed
        case sameStation
        case multipleJourneys
    }

    enum Stage: Equatable, Sendable {
        case details(Notice?)
        case matching
        case existing(planID: UUID)
    }

    let search: JourneySearchStore
    private(set) var stage: Stage = .details(nil)
    private(set) var suggestion: TicketRouteSuggestion
    private(set) var isPreparingSearch = false
    var showsAllFields = false

    private(set) var origin: String
    private(set) var destination: String
    private(set) var originPlace: RailPlace?
    private(set) var destinationPlace: RailPlace?
    private var revealedFields: Set<Field> = []
    private(set) var trainNumber: String
    private(set) var departure: TicketWallClock?
    /// Preserve explicit offsets through repeated DST hours until the person changes the time.
    private var departureInstant: Date?
    private(set) var timeChecked: Bool
    /// Only an explicitly zoned departure fixes the instant before station lookup.
    let knownTimeZone: TimeZone?
    private let ticketLackedTime: Bool

    @ObservationIgnored private let plans: @MainActor () -> [TrackedJourneyPlan]
    @ObservationIgnored private let client: any JourneySearching
    @ObservationIgnored private let linkedPlanIDs: Set<UUID>
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var matchingGeneration = 0
    @ObservationIgnored private var matchingTask: Task<Void, Never>?
    @ObservationIgnored private var planIDsBeforeMatching: Set<UUID> = []
    @ObservationIgnored var onDraftChange: ((TicketRouteSuggestion) -> Void)?

    init(
        suggestion: TicketRouteSuggestion,
        client: any JourneySearching,
        planTracker: any JourneyPlanTracking,
        plans: @escaping @MainActor () -> [TrackedJourneyPlan],
        linkedPlanIDs: Set<UUID> = [],
        now: @escaping () -> Date = Date.init
    ) {
        search = JourneySearchStore(client: client, planTracker: planTracker)
        self.client = client
        self.suggestion = suggestion
        self.plans = plans
        self.linkedPlanIDs = linkedPlanIDs
        self.now = now
        origin = suggestion.originGuess ?? ""
        destination = suggestion.destinationGuess ?? ""
        originPlace = TicketJourneySearchRequest.recognizedStation(suggestion.originPlace, named: suggestion.originGuess ?? "")
        destinationPlace = TicketJourneySearchRequest.recognizedStation(suggestion.destinationPlace, named: suggestion.destinationGuess ?? "")
        trainNumber = suggestion.trainNumberGuess ?? ""
        let initialDeparture: TicketWallClock?
        if suggestion.usesBoardingStationTime {
            knownTimeZone = nil
            departureInstant = nil
            initialDeparture = suggestion.calendarLocalDeparture
        } else if suggestion.departureWallClock == nil && suggestion.departureDate != nil {
            let zone = suggestion.departureTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
            knownTimeZone = zone
            departureInstant = suggestion.requiresDepartureTime ? nil : suggestion.departureDate
            initialDeparture = suggestion.departureDate.map {
                TicketWallClock(date: $0, timeZone: zone, includesTime: !suggestion.requiresDepartureTime)
            }
        } else {
            knownTimeZone = nil
            departureInstant = nil
            initialDeparture = suggestion.departureWallClock
        }
        departure = initialDeparture
        // Any time the source did not print must be checked explicitly, including placeholders.
        ticketLackedTime = suggestion.requiresDepartureTime || initialDeparture?.hasTime != true
        timeChecked = !ticketLackedTime
    }

    // MARK: - Details

    var missingFields: [Field] {
        var fields: [Field] = []
        let from = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if from.isEmpty { fields.append(.origin) }
        if to.isEmpty { fields.append(.destination) }
        let sameStation: Bool
        if let originPlace, let destinationPlace {
            sameStation = originPlace.id == destinationPlace.id
        } else {
            sameStation = !from.isEmpty && !to.isEmpty && from.localizedCaseInsensitiveCompare(to) == .orderedSame
        }
        if sameStation {
            fields.append(.destination)
        }
        if departure == nil { fields.append(.date) }
        if departure?.hasTime != true || !timeChecked || invalidLocalTime { fields.append(.time) }
        return fields
    }

    /// Fields shown before "Edit all details": only what is missing, plus any unmatched station.
    var visibleFields: [Field] {
        guard !showsAllFields else { return Field.allCases }
        var fields = missingFields + Array(revealedFields)
        if case let .details(.stationNotFound(origin, destination)) = stage {
            if origin, !fields.contains(.origin) { fields.insert(.origin, at: 0) }
            if destination, !fields.contains(.destination) { fields.append(.destination) }
        }
        return Field.allCases.filter(fields.contains)
    }

    var requiresTimeCheck: Bool { ticketLackedTime }

    var departureTimeZone: TimeZone? {
        knownTimeZone ?? originPlace.flatMap { TimeZone(identifier: $0.timeZoneIdentifier) }
    }

    var isComplete: Bool { missingFields.isEmpty }

    private var invalidLocalTime: Bool {
        guard suggestion.usesBoardingStationTime, let departure, departure.hasTime,
              let zone = departureTimeZone else { return false }
        return departure.exactTime(in: zone) == nil
    }

    /// Approximate instant used only to warn about a date that has already passed.
    var estimatedDeparture: Date? {
        if let departureInstant { return departureInstant }
        guard let departure else { return nil }
        let zone = departureTimeZone
            ?? TicketTextDetails.stationTimeZone(origin).flatMap(TimeZone.init(identifier:))
            ?? .autoupdatingCurrent
        return departure.date(in: zone)
    }

    var isPastDeparture: Bool {
        guard let estimatedDeparture else { return false }
        return estimatedDeparture < now().addingTimeInterval(-3_600)
    }

    func setOrigin(_ value: String) {
        guard value != origin else { return }
        revealStationField(.origin)
        origin = value
        originPlace = nil
        clearStationNotice()
        draftChanged(originWasReviewed: true)
    }

    func setDestination(_ value: String) {
        guard value != destination else { return }
        revealStationField(.destination)
        destination = value
        destinationPlace = nil
        clearStationNotice()
        draftChanged(destinationWasReviewed: true)
    }

    /// Keep a missing field in the form after its first letter, so focus is never removed.
    func revealStationField(_ field: Field) {
        guard field == .origin || field == .destination else { return }
        revealedFields.insert(field)
    }

    func selectStation(_ place: RailPlace, for field: Field) {
        guard place.kind == .station else { return }
        revealStationField(field)
        switch field {
        case .origin:
            origin = place.displayName
            originPlace = place
        case .destination:
            destination = place.displayName
            destinationPlace = place
        case .date, .time:
            return
        }
        clearStationNotice()
        draftChanged(originWasReviewed: field == .origin ? true : nil,
                     destinationWasReviewed: field == .destination ? true : nil)
    }

    func stationSuggestions(for query: String) async throws -> [RailPlace] {
        let lookup = ImportedStationAlias.lookupQuery(for: query) ?? query
        let places = try await client.searchPlaces(query: lookup, limit: 20)
        try Task.checkCancellation()
        var seen: Set<RailIdentifier> = []
        return places.filter { $0.kind == .station && seen.insert($0.id).inserted }
    }

    private func clearStationNotice() {
        switch stage {
        case .details(.stationNotFound), .details(.sameStation): stage = .details(nil)
        default: break
        }
    }

    func setTrainNumber(_ value: String) {
        guard value != trainNumber else { return }
        trainNumber = value
        draftChanged()
    }

    func setDay(year: Int, month: Int, day: Int) {
        if departure == nil { revealedFields.insert(.date) }
        var next = departure ?? TicketWallClock(year: year, month: month, day: day)
        next.year = year
        next.month = month
        next.day = day
        guard next != departure else { return }
        departureInstant = nil
        departure = next
        draftChanged()
    }

    func setTime(hour: Int, minute: Int) {
        guard var next = departure else { return }
        next.hour = hour
        next.minute = minute
        guard next != departure else { return }
        departureInstant = nil
        departure = next
        // A time the ticket never printed still needs the explicit check below.
        if !ticketLackedTime { timeChecked = true }
        draftChanged()
    }

    func setTimeChecked(_ checked: Bool) {
        guard departure?.hasTime == true, checked != timeChecked else { return }
        timeChecked = checked
        draftChanged()
    }

    // MARK: - Flow

    /// Opens an equivalent saved journey, starts matching for a complete import, or asks only
    /// for what is missing. A past date is shown before any search.
    func start() {
        guard stage == .details(nil) else { return }
        if let existing = existingPlan() {
            stage = .existing(planID: existing.id)
        } else if suggestion.routeReviewReason == .multipleJourneys {
            stage = .details(.multipleJourneys)
        } else if invalidLocalTime {
            stage = .details(.invalidLocalTime)
        } else if !isComplete {
            stage = .details(.missingDetails)
        } else if isPastDeparture {
            stage = .details(.pastDeparture)
        } else {
            beginMatching()
        }
    }

    var canBeginMatching: Bool { isComplete && makeRequest() != nil }

    func beginMatching() {
        guard let request = makeRequest() else {
            stage = .details(.missingDetails)
            return
        }
        if let existing = existingPlan() {
            stage = .existing(planID: existing.id)
            return
        }
        matchingGeneration += 1
        let generation = matchingGeneration
        planIDsBeforeMatching = Set(plans().map(\.id))
        search.importDraftSeed = suggestion.id
        stage = .matching
        isPreparingSearch = true
        matchingTask?.cancel()
        matchingTask = Task { [weak self] in
            guard let self, !Task.isCancelled,
                  self.matchingGeneration == generation, self.stage == .matching else { return }
            await self.search.prefillTicketJourney(request)
            guard self.matchingGeneration == generation, self.stage == .matching else { return }
            self.isPreparingSearch = false
            self.inspectPrefill()
        }
    }

    /// Preserves every entered field; only the network work is discarded.
    func editDetails() {
        cancelMatching()
        search.editSearch()
        showsAllFields = true
        stage = .details(nil)
    }

    func cancelMatching() {
        matchingGeneration += 1
        matchingTask?.cancel()
        matchingTask = nil
        isPreparingSearch = false
        search.cancelJourneyWork()
    }

    func retry() {
        beginMatching()
    }

    func wasCreated(planID: UUID) -> Bool {
        !planIDsBeforeMatching.contains(planID)
    }

    /// A selected journey already saved as another plan opens that plan instead of tracking a
    /// duplicate. A changed Calendar event may still update its own saved journey.
    func existingPlan(forSelected option: JourneyOption) -> TrackedJourneyPlan? {
        plans().first { plan in
            let sameJourney = plan.outbound.fingerprint == option.fingerprint
                || plan.returnDirection?.fingerprint == option.fingerprint
            guard sameJourney else { return false }
            if let source = suggestion.calendarSource, plan.calendarSource?.eventKey == source.eventKey,
               plan.calendarSource?.revision != source.revision {
                return false
            }
            return true
        }
    }

    func existingPlan() -> TrackedJourneyPlan? {
        guard suggestion.routeReviewReason != .ambiguousTrain else { return nil }
        return Self.existingPlan(
            linkedPlanIDs: suggestion.routeReviewReason == .multipleJourneys ? [] : linkedPlanIDs,
            calendarSource: suggestion.calendarSource,
            origin: origin, destination: destination, trainNumber: trainNumber,
            departure: departure?.hasTime == true && timeChecked ? departure : nil,
            knownTimeZone: knownTimeZone, plans: plans(),
            originPlace: originPlace, destinationPlace: destinationPlace, departureInstant: departureInstant
        )
    }

    static func existingPlan(
        linkedPlanIDs: Set<UUID>, calendarSource: CalendarJourneySource?,
        origin: String, destination: String, trainNumber: String,
        departure: TicketWallClock?, knownTimeZone: TimeZone?, plans: [TrackedJourneyPlan],
        originPlace: RailPlace? = nil, destinationPlace: RailPlace? = nil, departureInstant: Date? = nil
    ) -> TrackedJourneyPlan? {
        if let linked = plans.first(where: { linkedPlanIDs.contains($0.id) }) { return linked }
        if let source = calendarSource {
            // A changed revision continues to the update review; the same revision is already added.
            return plans.first { $0.calendarSource?.eventKey == source.eventKey && $0.calendarSource?.revision == source.revision }
        }
        return ImportedSavedJourneyMatcher.match(
            origin: origin, destination: destination, trainNumber: trainNumber,
            departure: departure, departureInstant: departureInstant, knownTimeZone: knownTimeZone,
            plans: plans, originPlace: originPlace, destinationPlace: destinationPlace
        )
    }

    func makeRequest() -> TicketJourneySearchRequest? {
        guard isComplete, let departure, departure.hasTime else { return nil }
        let from = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = trainNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = departureInstant ?? knownTimeZone.flatMap({ departure.date(in: $0) }) {
            let reviewed = suggestion.journeySearchRequest(
                origin: from, destination: to, trainNumber: number, departureDate: date
            )
            return TicketJourneySearchRequest(
                originName: reviewed.originName, destinationName: reviewed.destinationName,
                departureTime: reviewed.departureTime, trainNumber: reviewed.trainNumber,
                calendarSource: reviewed.calendarSource, prefersDirectReview: suggestion.routeReviewReason != .ambiguousTrain,
                originPlace: originPlace, destinationPlace: destinationPlace
            )
        }
        return suggestion.localTimeRequest(
            origin: from, destination: to, trainNumber: number, departure: departure,
            originPlace: originPlace, destinationPlace: destinationPlace,
            prefersDirectReview: suggestion.routeReviewReason != .ambiguousTrain
        )
    }

    private func inspectPrefill() {
        switch search.phase {
        case .editing:
            if search.placeLookupFailed {
                stage = .details(.lookupFailed)
            } else if search.form.origin == nil || search.form.destination == nil {
                if search.form.origin == nil { revealStationField(.origin) }
                if search.form.destination == nil { revealStationField(.destination) }
                stage = .details(.stationNotFound(origin: search.form.origin == nil, destination: search.form.destination == nil))
            } else if let from = search.form.origin, let to = search.form.destination, from.id == to.id {
                origin = from.displayName
                destination = to.displayName
                originPlace = from
                destinationPlace = to
                revealStationField(.destination)
                stage = .details(.sameStation)
                draftChanged()
            } else if suggestion.usesBoardingStationTime, let from = search.form.origin {
                originPlace = from
                revealedFields.insert(.time)
                stage = .details(invalidLocalTime ? .invalidLocalTime : .missingDetails)
            } else {
                stage = .details(.missingDetails)
            }
        default:
            break
        }
    }

    private func draftChanged(originWasReviewed: Bool? = nil, destinationWasReviewed: Bool? = nil) {
        let number = trainNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsTime = departure?.hasTime != true || !timeChecked
        suggestion = suggestion.revised(
            origin: .some(origin.isEmpty ? nil : origin),
            destination: .some(destination.isEmpty ? nil : destination),
            trainNumber: .some(number.isEmpty ? nil : number),
            departureDate: .some(departureInstant ?? knownTimeZone.flatMap { zone in departure.flatMap { $0.date(in: zone) } }),
            requiresDepartureTime: needsTime,
            departureWallClock: .some(knownTimeZone == nil ? departure : nil),
            originPlace: .some(originPlace), destinationPlace: .some(destinationPlace),
            originWasReviewed: originWasReviewed, destinationWasReviewed: destinationWasReviewed
        )
        if case .details(let notice) = stage, isComplete, notice == .missingDetails || notice == .invalidLocalTime {
            stage = .details(nil)
        }
        onDraftChange?(suggestion)
    }
}

import Foundation
import TrainTrackerCore

enum TicketRouteReviewReason: String, Codable, Hashable, Sendable {
    case multipleJourneys
    case ambiguousTrain
}

/// A single reviewable suggestion, produced either from a calendar candidate or a share-extension
/// import. The review screen lets the person correct anything before it becomes a real search.
struct TicketRouteSuggestion: Identifiable, Sendable, Hashable, Codable {
    let id: UUID
    let sourceDescription: String
    let subtitle: String?
    let originGuess: String?
    let destinationGuess: String?
    let trainNumberGuess: String?
    let departureDate: Date?
    let confidence: TicketRouteConfidence?
    let evidence: [String]
    let requiresDepartureTime: Bool
    let departureTimeZoneIdentifier: String?
    let calendarSource: CalendarJourneySource?
    /// Civil time printed on a ticket or read from a floating Calendar event.
    let departureWallClock: TicketWallClock?
    /// The Calendar event's own all-day flag, kept after the person supplies a departure time.
    let isAllDayEvent: Bool?
    /// Explicit station choices survive closing an unfinished review. Older drafts omit these.
    let originPlace: RailPlace?
    let destinationPlace: RailPlace?
    /// Distinguishes legacy missing guesses from a station the person deliberately cleared.
    let originWasReviewed: Bool?
    let destinationWasReviewed: Bool?
    /// Older saved imports omit this. Complex bookings need an explicit choice of one journey.
    let routeReviewReason: TicketRouteReviewReason?

    init(
        id: UUID = UUID(),
        sourceDescription: String,
        subtitle: String? = nil,
        originGuess: String? = nil,
        destinationGuess: String? = nil,
        trainNumberGuess: String? = nil,
        departureDate: Date? = nil,
        confidence: TicketRouteConfidence? = nil,
        evidence: [String] = [],
        requiresDepartureTime: Bool = false,
        departureTimeZoneIdentifier: String? = nil,
        calendarSource: CalendarJourneySource? = nil,
        departureWallClock: TicketWallClock? = nil,
        isAllDayEvent: Bool? = nil,
        originPlace: RailPlace? = nil,
        destinationPlace: RailPlace? = nil,
        originWasReviewed: Bool? = nil,
        destinationWasReviewed: Bool? = nil,
        routeReviewReason: TicketRouteReviewReason? = nil
    ) {
        self.id = id
        self.sourceDescription = sourceDescription
        self.subtitle = subtitle
        self.originGuess = originGuess
        self.destinationGuess = destinationGuess
        self.trainNumberGuess = trainNumberGuess
        self.departureDate = departureDate
        self.confidence = confidence
        self.evidence = evidence
        self.requiresDepartureTime = requiresDepartureTime
        self.departureTimeZoneIdentifier = departureTimeZoneIdentifier
        self.calendarSource = calendarSource
        self.departureWallClock = departureWallClock
        self.isAllDayEvent = isAllDayEvent
        self.originPlace = TicketJourneySearchRequest.recognizedStation(originPlace, named: originGuess ?? "")
        self.destinationPlace = TicketJourneySearchRequest.recognizedStation(destinationPlace, named: destinationGuess ?? "")
        self.originWasReviewed = originWasReviewed
        self.destinationWasReviewed = destinationWasReviewed
        self.routeReviewReason = routeReviewReason
    }

    func journeySearchRequest(origin: String, destination: String, trainNumber: String?, departureDate: Date) -> TicketJourneySearchRequest {
        let reviewedOrigin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let reviewedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let reviewedNumber = trainNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = reviewedNumber?.isEmpty == false ? reviewedNumber : nil
        let reviewedSource = calendarSource.map { source in
            CalendarJourneySource(
                eventKey: source.eventKey, revision: source.revision,
                details: CalendarJourneyDetails(
                    originName: reviewedOrigin, destinationName: reviewedDestination, trainNumber: number,
                    departureDate: departureDate, timeZoneIdentifier: departureTimeZoneIdentifier,
                    isAllDay: isAllDayEvent ?? requiresDepartureTime
                )
            )
        }
        return TicketJourneySearchRequest(
            originName: reviewedOrigin,
            destinationName: reviewedDestination,
            departureTime: ISO8601DateFormatter().string(from: departureDate),
            trainNumber: number,
            calendarSource: reviewedSource,
            originPlace: originPlace, destinationPlace: destinationPlace
        )
    }

    var usesBoardingStationTime: Bool {
        calendarSource != nil && ((isAllDayEvent ?? requiresDepartureTime)
            || departureTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) == nil)
    }

    var calendarLocalDeparture: TicketWallClock? {
        guard usesBoardingStationTime else { return nil }
        // New drafts already captured the civil components when EventKit was read.
        return departureWallClock ?? departureDate.map {
            TicketWallClock(date: $0, timeZone: NSTimeZone.default, includesTime: !requiresDepartureTime)
        }
    }

    func localTimeRequest(
        origin: String, destination: String, trainNumber: String?, departure: TicketWallClock,
        originPlace: RailPlace?, destinationPlace: RailPlace?, prefersDirectReview: Bool = false
    ) -> TicketJourneySearchRequest {
        let number = trainNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TicketJourneySearchRequest(
            originName: origin, destinationName: destination, departureTime: departure.requestValue,
            trainNumber: number?.isEmpty == false ? number : nil, calendarSource: calendarSource,
            prefersDirectReview: prefersDirectReview, originPlace: originPlace, destinationPlace: destinationPlace,
            localCalendarTiming: calendarSource.map { _ in
                .init(isAllDay: isAllDayEvent ?? requiresDepartureTime, eventTimeZoneIdentifier: departureTimeZoneIdentifier)
            }
        )
    }

    /// For civil time the date picker uses GMT solely as a stable calendar for its number wheels.
    func requestFromDatePicker(origin: String, destination: String, trainNumber: String?, value: Date) -> TicketJourneySearchRequest {
        guard usesBoardingStationTime else {
            return journeySearchRequest(origin: origin, destination: destination, trainNumber: trainNumber, departureDate: value)
        }
        return localTimeRequest(
            origin: origin, destination: destination, trainNumber: trainNumber,
            departure: TicketWallClock(date: value, timeZone: .gmt, includesTime: true),
            originPlace: originPlace, destinationPlace: destinationPlace
        )
    }

    /// Returns a copy with reviewed values. Identity, source and provenance are preserved.
    func revised(
        id: UUID? = nil,
        origin: String?? = nil,
        destination: String?? = nil,
        trainNumber: String?? = nil,
        departureDate: Date?? = nil,
        requiresDepartureTime: Bool? = nil,
        departureWallClock: TicketWallClock?? = nil,
        originPlace: RailPlace?? = nil,
        destinationPlace: RailPlace?? = nil,
        originWasReviewed: Bool? = nil,
        destinationWasReviewed: Bool? = nil
    ) -> Self {
        Self(
            id: id ?? self.id, sourceDescription: sourceDescription, subtitle: subtitle,
            originGuess: origin ?? originGuess, destinationGuess: destination ?? destinationGuess,
            trainNumberGuess: trainNumber ?? trainNumberGuess, departureDate: departureDate ?? self.departureDate,
            confidence: confidence, evidence: evidence,
            requiresDepartureTime: requiresDepartureTime ?? self.requiresDepartureTime,
            departureTimeZoneIdentifier: departureTimeZoneIdentifier, calendarSource: calendarSource,
            departureWallClock: departureWallClock ?? self.departureWallClock,
            isAllDayEvent: isAllDayEvent,
            originPlace: originPlace ?? self.originPlace,
            destinationPlace: destinationPlace ?? self.destinationPlace,
            originWasReviewed: originWasReviewed ?? self.originWasReviewed,
            destinationWasReviewed: destinationWasReviewed ?? self.destinationWasReviewed,
            routeReviewReason: routeReviewReason
        )
    }

    /// Older Calendar drafts may predate support for a station spelling in their title.
    /// Recover missing endpoints locally without replacing reviewed stations, times or identity.
    func restoringMissingCalendarRoute() -> Self {
        let missingOrigin = originWasReviewed != true && (originGuess?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let missingDestination = destinationWasReviewed != true && (destinationGuess?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard calendarSource != nil, missingOrigin || missingDestination,
              let subtitle, let route = TicketRouteTextParser.extract(from: subtitle) else { return self }
        return revised(
            origin: missingOrigin ? route.origin : originGuess,
            destination: missingDestination ? route.destination : destinationGuess
        )
    }
}

extension CalendarJourneyCandidate {
    var routeSuggestion: TicketRouteSuggestion {
        let localClock = snapshot.isAllDay || snapshot.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) == nil
            ? TicketWallClock(date: snapshot.startDate, timeZone: snapshot.readTimeZone, includesTime: !snapshot.isAllDay)
            : nil
        return TicketRouteSuggestion(
            sourceDescription: snapshot.calendarTitle,
            subtitle: snapshot.title,
            originGuess: classification.originGuess,
            destinationGuess: classification.destinationGuess,
            trainNumberGuess: classification.trainNumberGuess,
            departureDate: snapshot.startDate,
            confidence: classification.confidence,
            evidence: classification.evidence,
            requiresDepartureTime: snapshot.isAllDay,
            departureTimeZoneIdentifier: snapshot.timeZoneIdentifier,
            calendarSource: snapshot.importSource,
            departureWallClock: localClock,
            isAllDayEvent: snapshot.isAllDay,
            routeReviewReason: classification.hasConflictingTrainProducts ? .ambiguousTrain : nil
        )
    }
}

extension TicketRouteSuggestion {
    /// Carries a detail-reviewed Calendar request into the same smart review as every import.
    init(reviewed request: TicketJourneySearchRequest, from base: TicketRouteSuggestion) {
        let date = request.departureTime.flatMap { ISO8601DateFormatter().date(from: $0) }
        let localClock = request.departureTime.flatMap(TicketWallClock.init(requestValue:))
        self.init(
            id: base.id, sourceDescription: base.sourceDescription, subtitle: base.subtitle,
            originGuess: request.originName, destinationGuess: request.destinationName,
            trainNumberGuess: request.trainNumber, departureDate: date ?? base.departureDate,
            confidence: base.confidence, evidence: base.evidence,
            // The detail review already required an all-day event's time to be checked.
            requiresDepartureTime: false,
            departureTimeZoneIdentifier: base.departureTimeZoneIdentifier,
            calendarSource: base.calendarSource, departureWallClock: localClock,
            isAllDayEvent: base.isAllDayEvent,
            originPlace: request.originPlace ?? base.originPlace,
            destinationPlace: request.destinationPlace ?? base.destinationPlace,
            originWasReviewed: true, destinationWasReviewed: true,
            routeReviewReason: base.routeReviewReason
        )
    }
}

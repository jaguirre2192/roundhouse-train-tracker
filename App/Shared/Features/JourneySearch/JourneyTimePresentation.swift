import Foundation
import TrainTrackerCore

struct JourneyTimePresentation: Equatable {
    let departure: String
    let arrival: String
    let arrivalDayContext: String?
    let duration: String
}

struct JourneyAccessibilityPart: Equatable {
    enum Kind: Equatable {
        case departure
        case arrival
        case duration
        case changes
        case status
        case trackability
    }

    let kind: Kind
    let value: String
}

struct JourneyOptionPresentation: Equatable {
    let time: JourneyTimePresentation
    let originStation: String
    let destinationStation: String
    let changes: String
    let trainIdentities: [String]
    let badges: [String]
    let recommendationBadge: String?
    let transferWarning: String?
    let departurePlatform: String?
    let arrivalPlatform: String?
    let status: String?
    let trackability: String
    let accessibilityParts: [JourneyAccessibilityPart]

    var accessibilityLabel: String {
        accessibilityParts.map(\.value).joined(separator: ", ")
    }

    init(option: JourneyOption) {
        let railSegments = option.segments.compactMap(\.railSegment)
        let firstRail = railSegments.first
        let lastRail = railSegments.last
        let endpointDates = option.effectiveEndpointDates
        let departure = endpointDates.departure
        let arrival = endpointDates.arrival
        let departureZone = JourneyPresentationFormatter.timeZone(
            firstRail?.from.place.timeZoneIdentifier
        )
        let arrivalZone = JourneyPresentationFormatter.timeZone(
            lastRail?.to.place.timeZoneIdentifier
        )
        let time = JourneyTimePresentation(
            departure: JourneyPresentationFormatter.time(departure, in: departureZone),
            arrival: JourneyPresentationFormatter.time(arrival, in: arrivalZone),
            arrivalDayContext: JourneyPresentationFormatter.dayContext(
                departure: departure,
                departureZone: departureZone,
                arrival: arrival,
                arrivalZone: arrivalZone
            ),
            duration: JourneyPresentationFormatter.duration(arrival.timeIntervalSince(departure))
        )
        let originStation = firstRail?.from.place.displayName
            ?? JourneySearchCopy.Status.originUnavailable
        let destinationStation = lastRail?.to.place.displayName
            ?? JourneySearchCopy.Status.destinationUnavailable
        let changes = JourneyPresentationFormatter.changes(option.transferCount)
        let status = JourneyPresentationFormatter.status(
            railSegments: railSegments,
            realtimeFreshness: option.realtimeFreshness
        )
        let trackability = JourneyPresentationFormatter.trackability(option.trackability)
        let daySuffix = time.arrivalDayContext.map { " \($0)" } ?? ""

        self.time = time
        self.originStation = originStation
        self.destinationStation = destinationStation
        self.changes = changes
        trainIdentities = railSegments.map(JourneyPresentationFormatter.trainIdentity)
        badges = option.badges.map(\.presentationTitle)
        recommendationBadge = Self.recommendationBadge(from: option.badges)
        transferWarning = option.segments.lazy.compactMap { segment -> String? in
            guard case let .walk(walk) = segment, walk.isStationChange else { return nil }
            return JourneySearchCopy.Status.stationChange(at: walk.from.displayName)
        }.first
        departurePlatform = JourneyPresentationFormatter.platform(firstRail?.from)
        arrivalPlatform = JourneyPresentationFormatter.platform(lastRail?.to)
        self.status = status
        self.trackability = trackability
        var parts = [
            JourneyAccessibilityPart(
                kind: .departure,
                value: JourneySearchCopy.Accessibility.departure(
                    time: time.departure,
                    station: originStation
                )
            ),
            JourneyAccessibilityPart(
                kind: .arrival,
                value: JourneySearchCopy.Accessibility.arrival(
                    time: time.arrival,
                    daySuffix: daySuffix,
                    station: destinationStation
                )
            ),
            JourneyAccessibilityPart(
                kind: .duration,
                value: JourneySearchCopy.Accessibility.duration(time.duration)
            ),
            JourneyAccessibilityPart(kind: .changes, value: changes),
        ]
        if let status {
            parts.append(JourneyAccessibilityPart(kind: .status, value: status))
        }
        parts.append(JourneyAccessibilityPart(kind: .trackability, value: trackability))
        accessibilityParts = parts
    }

    private static func recommendationBadge(from badges: [JourneyBadge]) -> String? {
        if badges.contains(.fastest) { return JourneySearchCopy.Status.fastest }
        if badges.contains(.fewestChanges) { return JourneySearchCopy.Status.fewestChanges }
        return nil
    }
}

struct JourneyCallPresentation: Equatable, Identifiable {
    let id: String
    let station: String
    let scheduledTime: String?
    let expectedTime: String?
    let platform: String?
    let isCancelled: Bool

    var displayTime: String? {
        expectedTime ?? scheduledTime
    }

    var hasTimingUpdate: Bool {
        guard let expectedTime, let scheduledTime else { return false }
        return expectedTime != scheduledTime
    }
}

struct JourneySegmentPresentation: Equatable, Identifiable {
    enum Kind: Equatable {
        case rail
        case walk
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String?
    let calls: [JourneyCallPresentation]
    let duration: String?
    let distance: String?
    let warning: String?
    let trackability: String?
    let isCancelled: Bool

    static func makeAll(from option: JourneyOption) -> [Self] {
        option.segments.map(make)
    }

    static func make(from segment: JourneySegment) -> Self {
        switch segment {
        case let .rail(rail): railPresentation(rail)
        case let .walk(walk): walkPresentation(walk)
        }
    }

    private static func railPresentation(_ rail: RailJourneySegment) -> Self {
        let calls = [rail.from] + rail.intermediateCalls + [rail.to]
        return JourneySegmentPresentation(
            id: rail.id,
            kind: .rail,
            title: JourneyPresentationFormatter.trainIdentity(rail),
            subtitle: rail.product,
            calls: calls.enumerated().map { index, call in
                JourneyPresentationFormatter.call(
                    call,
                    id: "\(rail.id)-call-\(index)",
                    preferDeparture: index < calls.count - 1
                )
            },
            duration: nil,
            distance: nil,
            warning: nil,
            trackability: rail.isTrackable
                ? JourneySearchCopy.Status.trackable
                : JourneySearchCopy.Status.notTrackable(
                    reason: rail.untrackableReason ?? JourneySearchCopy.Status.providerCannotTrack
                ),
            isCancelled: rail.isCancelled
        )
    }

    private static func walkPresentation(_ walk: WalkJourneySegment) -> Self {
        JourneySegmentPresentation(
            id: walk.id,
            kind: .walk,
            title: JourneySearchCopy.Status.walkTo(walk.to.displayName),
            subtitle: JourneySearchCopy.Status.from(walk.from.displayName),
            calls: [],
            duration: JourneySearchCopy.Status.walkDuration(
                JourneyPresentationFormatter.duration(walk.duration)
            ),
            distance: walk.distance.map(JourneyPresentationFormatter.distance),
            warning: walk.isStationChange ? JourneySearchCopy.Status.stationChangeRequired : nil,
            trackability: nil,
            isCancelled: false
        )
    }
}

enum JourneyResultFiltering {
    static func options(in options: [JourneyOption], directOnly: Bool) -> [JourneyOption] {
        let filtered = directOnly ? options.filter { $0.transferCount == 0 } : options
        return filtered.sorted {
            let firstDeparture = $0.effectiveEndpointDates.departure
            let secondDeparture = $1.effectiveEndpointDates.departure
            if firstDeparture != secondDeparture { return firstDeparture < secondDeparture }
            return $0.id < $1.id
        }
    }
}

private enum JourneyPresentationFormatter {
    static let locale = Locale(identifier: "en_US_POSIX")

    static func timeZone(_ identifier: String?) -> TimeZone {
        identifier.flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)!
    }

    static func time(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = TimeFormatPreference.stored().clockPattern()
        return formatter.string(from: date)
    }

    static func dayContext(
        departure: Date,
        departureZone: TimeZone,
        arrival: Date,
        arrivalZone: TimeZone
    ) -> String? {
        let departureOrdinal = localDayOrdinal(departure, in: departureZone)
        let arrivalOrdinal = localDayOrdinal(arrival, in: arrivalZone)
        let difference = arrivalOrdinal - departureOrdinal
        if difference == 0 { return nil }
        if difference == 1 { return "+1" }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = arrivalZone
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: arrival)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let totalMinutes = max(Int(interval.rounded()) / 60, 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    static func changes(_ count: Int) -> String {
        JourneySearchCopy.Status.changes(count)
    }

    static func platform(_ call: JourneyCall?) -> String? {
        guard let value = call?.expectedPlatform ?? call?.plannedPlatform,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return JourneySearchCopy.Status.platform(value)
    }

    static func trainIdentity(_ rail: RailJourneySegment) -> String {
        let service: String
        if let name = rail.trainName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            service = name
        } else if let number = rail.trainNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !number.isEmpty {
            service = "\(rail.product) \(number)"
        } else {
            service = rail.product
        }
        let operatorName = rail.operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !operatorName.isEmpty,
           service.range(of: operatorName, options: [.anchored, .caseInsensitive]) != nil {
            return service
        }
        return "\(operatorName) · \(service)"
    }

    static func status(
        railSegments: [RailJourneySegment],
        realtimeFreshness: Date?
    ) -> String? {
        if railSegments.contains(where: { $0.isCancelled || $0.from.isCancelled || $0.to.isCancelled }) {
            return JourneySearchCopy.Status.cancelled
        }
        if realtimeFreshness != nil || railSegments.contains(where: \.isRealtime) {
            return JourneySearchCopy.Status.liveTimes
        }
        return nil
    }

    static func trackability(_ value: JourneyTrackability) -> String {
        JourneySearchCopy.Status.trackability(
            trackable: value.trackableRailSegments,
            total: value.totalRailSegments
        )
    }

    static func distance(_ meters: Double) -> String {
        if meters < 1_000 { return "\(Int(meters.rounded())) m" }
        return String(format: "%.1f km", locale: locale, meters / 1_000)
    }

    static func call(
        _ call: JourneyCall,
        id: String,
        preferDeparture: Bool
    ) -> JourneyCallPresentation {
        let scheduledDate = preferDeparture
            ? call.scheduledDeparture ?? call.scheduledArrival
            : call.scheduledArrival ?? call.scheduledDeparture
        let expectedDate = preferDeparture
            ? call.expectedDeparture ?? call.expectedArrival
            : call.expectedArrival ?? call.expectedDeparture
        let zone = timeZone(call.place.timeZoneIdentifier)
        return JourneyCallPresentation(
            id: id,
            station: call.place.displayName,
            scheduledTime: scheduledDate.map { time($0, in: zone) },
            expectedTime: expectedDate.map { time($0, in: zone) },
            platform: platform(call),
            isCancelled: call.isCancelled
        )
    }

    private static func localDayOrdinal(_ date: Date, in timeZone: TimeZone) -> Int {
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = timeZone
        let components = localCalendar.dateComponents([.year, .month, .day], from: date)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let normalized = utcCalendar.date(from: components) ?? date
        return Int(normalized.timeIntervalSince1970 / 86_400)
    }
}

private extension JourneySegment {
    var railSegment: RailJourneySegment? {
        guard case let .rail(segment) = self else { return nil }
        return segment
    }
}

private extension JourneyBadge {
    var presentationTitle: String {
        switch self {
        case .direct: JourneySearchCopy.Status.direct
        case .fastest: JourneySearchCopy.Status.fastest
        case .fewestChanges: JourneySearchCopy.Status.fewestChanges
        }
    }
}

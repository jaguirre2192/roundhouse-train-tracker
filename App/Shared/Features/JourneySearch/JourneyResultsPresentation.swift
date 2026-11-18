import Foundation
import TrainTrackerCore

struct JourneyResultsContext: Equatable {
    let origin: String
    let destination: String
    let requestedTime: Date
    let timeZoneIdentifier: String?
    let arriveBy: Bool
    /// The traveller's clock; the summary names the station's zone only when it differs.
    var deviceTimeZone: TimeZone = .autoupdatingCurrent

    init(direction: JourneySearchDirection, form: JourneySearchFormState) {
        switch direction {
        case .outbound:
            origin = form.origin?.displayName ?? JourneySearchCopy.Status.originUnavailable
            destination = form.destination?.displayName ?? JourneySearchCopy.Status.destinationUnavailable
            requestedTime = form.outboundTime
            timeZoneIdentifier = form.outboundTimeZoneIdentifier
            arriveBy = form.outboundArriveBy
        case .return:
            origin = form.destination?.displayName ?? JourneySearchCopy.Status.originUnavailable
            destination = form.origin?.displayName ?? JourneySearchCopy.Status.destinationUnavailable
            requestedTime = form.returnTime
            timeZoneIdentifier = form.returnTimeZoneIdentifier
            arriveBy = form.returnArriveBy
        }
    }

    var routeTitle: String {
        "\(origin) → \(destination)"
    }

    var timingSummary: String {
        let timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            ?? TimeZone(secondsFromGMT: 0)!
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "EEE, MMM d"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.calendar = Calendar(identifier: .gregorian)
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = TimeFormatPreference.stored().clockPattern()

        let mode = arriveBy
            ? JourneySearchCopy.Results.arrivingByShort
            : JourneySearchCopy.Results.departingAfterShort
        let zone = JourneyPlanDateTimePresentation.zoneSuffix(
            requestedTime, timeZoneIdentifier: timeZoneIdentifier, deviceTimeZone: deviceTimeZone
        ).map { " \($0)" } ?? ""
        return "\(dateFormatter.string(from: requestedTime)) · \(mode) \(timeFormatter.string(from: requestedTime))\(zone)"
    }
}

enum JourneyResultSortOrder: String, CaseIterable, Identifiable {
    case importedTrain
    case departure
    case fastest
    case fewestChanges

    var id: String { rawValue }

    var title: String {
        switch self {
        case .importedTrain: "Imported train"
        case .departure: JourneySearchCopy.Results.sortDeparture
        case .fastest: JourneySearchCopy.Results.sortFastest
        case .fewestChanges: JourneySearchCopy.Results.sortFewestChanges
        }
    }

    static func defaultOrder(preferredTrainNumber: String?) -> Self {
        JourneyImportedTrainPreference.isAvailable(preferredTrainNumber) ? .importedTrain : .departure
    }

    static func availableOrders(preferredTrainNumber: String?) -> [Self] {
        allCases.filter { $0 != .importedTrain || JourneyImportedTrainPreference.isAvailable(preferredTrainNumber) }
    }

    func sorted(_ options: [JourneyOption], preferredTrainNumber: String? = nil) -> [JourneyOption] {
        let ordered = options.sorted { lhs, rhs in
            let lhsDates = lhs.effectiveEndpointDates
            let rhsDates = rhs.effectiveEndpointDates
            let lhsDuration = lhsDates.arrival.timeIntervalSince(lhsDates.departure)
            let rhsDuration = rhsDates.arrival.timeIntervalSince(rhsDates.departure)

            switch self {
            case .importedTrain, .departure:
                if lhsDates.departure != rhsDates.departure {
                    return lhsDates.departure < rhsDates.departure
                }
            case .fastest:
                if lhsDuration != rhsDuration { return lhsDuration < rhsDuration }
                if lhsDates.departure != rhsDates.departure {
                    return lhsDates.departure < rhsDates.departure
                }
            case .fewestChanges:
                if lhs.transferCount != rhs.transferCount {
                    return lhs.transferCount < rhs.transferCount
                }
                if lhsDuration != rhsDuration { return lhsDuration < rhsDuration }
                if lhsDates.departure != rhsDates.departure {
                    return lhsDates.departure < rhsDates.departure
                }
            }
            return lhs.id < rhs.id
        }
        return self == .importedTrain
            ? JourneyImportedTrainPreference.ranked(ordered, trainNumber: preferredTrainNumber)
            : ordered
    }
}

enum JourneyResultsPresentation {
    static func rows(
        options: [JourneyOption],
        sortOrder: JourneyResultSortOrder,
        preferredTrainNumber: String?
    ) -> [JourneyResultRow] {
        sortOrder.sorted(options, preferredTrainNumber: preferredTrainNumber).map {
            JourneyResultRow(option: $0, preferredTrainNumber: preferredTrainNumber)
        }
    }
}

struct JourneyResultRow: Identifiable {
    let option: JourneyOption
    let presentation: JourneyOptionPresentation
    let importedTrainMatchLabel: String?

    var id: String { option.id }

    var accessibilityLabel: String {
        [presentation.accessibilityLabel, importedTrainMatchLabel].compactMap { $0 }.joined(separator: ". ")
    }

    init(option: JourneyOption, preferredTrainNumber: String?) {
        self.option = option
        presentation = JourneyOptionPresentation(option: option)
        importedTrainMatchLabel = JourneyImportedTrainPreference.matches(option, trainNumber: preferredTrainNumber)
            ? "Train number matches import" : nil
    }
}

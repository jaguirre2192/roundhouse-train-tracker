import Foundation
import TrainTrackerCore

enum JourneyReturnPageDisposition: Equatable {
    case results
    case terminalRecovery
}

enum JourneySearchPolicy {
    static func filterReturnPage(
        _ page: JourneySearchPage,
        after outbound: JourneyOption
    ) -> JourneySearchPage {
        let outboundArrival = outbound.effectiveEndpointDates.arrival
        return JourneySearchPage(
            generatedAt: page.generatedAt,
            expiresAt: page.expiresAt,
            options: page.options.filter {
                $0.effectiveEndpointDates.departure >= outboundArrival
            },
            previousCursor: page.previousCursor,
            nextCursor: page.nextCursor,
            warnings: page.warnings,
            attributions: page.attributions
        )
    }

    static func ceilToFiveMinutes(
        _ date: Date,
        timeZoneIdentifier: String?
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            calendar.timeZone = timeZone
        }
        let components = calendar.dateComponents([.minute, .second, .nanosecond], from: date)
        guard let minute = components.minute else { return date }
        let second = components.second ?? 0
        let nanosecond = components.nanosecond ?? 0
        if minute.isMultiple(of: 5), second == 0, nanosecond == 0 { return date }
        guard let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start else { return date }
        let minutes = 5 - (minute % 5)
        return calendar.date(byAdding: .minute, value: minutes, to: minuteStart) ?? date
    }

    static func returnPageDisposition(
        _ page: JourneySearchPage
    ) -> JourneyReturnPageDisposition {
        if !page.options.isEmpty || page.previousCursor != nil || page.nextCursor != nil {
            return .results
        }
        return .terminalRecovery
    }
}

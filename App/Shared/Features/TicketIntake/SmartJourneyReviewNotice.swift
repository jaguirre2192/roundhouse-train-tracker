import SwiftUI

struct SmartJourneyReviewNotice: View {
    let notice: SmartJourneyReviewStore.Notice
    let store: SmartJourneyReviewStore

    @ViewBuilder
    var body: some View {
        switch notice {
        case .missingDetails:
            Label(missingText, systemImage: "square.and.pencil")
                .font(.subheadline)
                .foregroundStyle(Color.ttTextPrimary)
        case .pastDeparture:
            Label("This departure date has already passed. Check the date on your ticket.", systemImage: "calendar.badge.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(Color.ttStatusDelayed)
        case .invalidLocalTime:
            Label("The clocks move forward at the departure station. Check the local time on your ticket.", systemImage: "clock.badge.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(Color.ttStatusDelayed)
        case let .stationNotFound(origin, destination):
            Label(stationNotFoundText(origin: origin, destination: destination), systemImage: "mappin.slash")
                .font(.subheadline)
                .foregroundStyle(Color.ttStatusDelayed)
        case .lookupFailed:
            Label("Couldn't reach the train search. Your details are saved on this device.", systemImage: "wifi.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(Color.ttStatusDelayed)
            Button("Try Again", action: store.retry)
                .accessibilityIdentifier("smartReviewRetry")
        case .sameStation:
            Label("Choose a different arrival station. Both names match the same station.", systemImage: "mappin.slash")
                .font(.subheadline)
                .foregroundStyle(Color.ttStatusDelayed)
        case .multipleJourneys:
            Label("This ticket contains several journeys. Choose one complete route and its departure time to track. The ticket stays in Unfinished so you can add the others, then choose Finish Reviewing Ticket.", systemImage: "arrow.triangle.branch")
                .font(.subheadline)
                .foregroundStyle(Color.ttStatusDelayed)
        }
    }

    private var missingText: String {
        let names = store.missingFields.map { field -> String in
            switch field {
            case .origin: "departure station"
            case .destination: "arrival station"
            case .date: "travel date"
            case .time: "departure time"
            }
        }
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard !unique.isEmpty else { return "Check the details, then find your train." }
        return "Add the \(ListFormatter.localizedString(byJoining: unique)) from your ticket."
    }

    private func stationNotFoundText(origin: Bool, destination: Bool) -> String {
        let names = [origin ? "“\(store.origin)”" : nil, destination ? "“\(store.destination)”" : nil].compactMap { $0 }
        return "We couldn't match \(ListFormatter.localizedString(byJoining: names)). Type a station or city name below, then choose a matching station."
    }
}

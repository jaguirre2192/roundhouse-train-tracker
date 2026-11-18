import SwiftUI
import TrainTrackerCore

struct TicketPurchaseItinerary: View {
    let journey: TicketPurchaseJourney

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
            Text("Journey to Match")
                .font(.title3.weight(.semibold))
            Text("Scheduled times at each station • not a reservation")
                .font(.caption)
                .foregroundStyle(Color.ttTextSecondary)
            ForEach(Array(journey.directions.enumerated()), id: \.offset) { index, direction in
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
                    if journey.returnDirection != nil {
                        Text(index == 0 ? "Outbound" : "Return")
                            .font(.headline)
                    }
                    ForEach(Array(direction.segments.enumerated()), id: \.offset) { _, segment in
                        switch segment {
                        case let .rail(leg):
                            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                                Label(leg.train, image: TrainTrackerSymbol.train)
                                    .font(.headline)
                                endpoint(leg.origin, date: leg.departure, zone: leg.departureTimeZone, label: "Departs")
                                endpoint(leg.destination, date: leg.arrival, zone: leg.arrivalTimeZone, label: "Arrives")
                            }
                            .accessibilityElement(children: .combine)
                        case let .walk(walk):
                            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                                Label("Walk to \(walk.destination)", systemImage: "figure.walk")
                                    .font(.subheadline.weight(.semibold))
                                Text(walk.detailsDescription)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.ttTextSecondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                        case let .legacyTransfer(transfer):
                            Label(transfer, systemImage: "figure.walk")
                                .font(.subheadline)
                                .foregroundStyle(Color.ttTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LayoutMetrics.cardInset)
                .trainTrackerSurface(color: .ttBackgroundBrandSubtle, radius: TrainTrackerRadius.group)
            }
        }
    }

    private func endpoint(_ station: String, date: Date, zone: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
            Text(station).font(.body.weight(.semibold))
            Text("\(label) \(TicketPurchaseJourney.localDate(date, timeZone: zone))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.ttTextSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private extension TicketPurchaseJourney.Walk {
    var detailsDescription: String {
        var details = ["From \(origin)", durationDescription]
        if let distanceDescription { details.append(distanceDescription) }
        if isStationChange { details.append("station change") }
        return details.joined(separator: " · ")
    }
}

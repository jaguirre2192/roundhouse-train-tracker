import SwiftUI
import TrainTrackerCore

/// How a train is running, as a dot and plain words: "On time", "7 min late", "Canceled".
/// There is no box and no capitals. Color is carried by the dot and, for a delay or a
/// cancellation, the words; everything else reads in the text color.
struct TripStatusLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    enum Emphasis {
        case standard
        case prominent
    }

    let trip: TrainTrip
    let emphasis: Emphasis
    let showIcon: Bool

    init(
        trip: TrainTrip,
        emphasis: Emphasis = .standard,
        showIcon: Bool = true
    ) {
        self.trip = trip
        self.emphasis = emphasis
        self.showIcon = showIcon
    }

    init(trip: TrainTrip, isProminent: Bool) {
        self.init(trip: trip, emphasis: isProminent ? .prominent : .standard)
    }

    var body: some View {
        let status = TripPresentationStatus(trip: trip)

        HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space6) {
            if showIcon {
                Circle()
                    .fill(status.color)
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
                    .accessibilityHidden(true)
            }

            Text(status.text)
                .font((emphasis == .prominent ? Font.subheadline : .footnote).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(textColor(for: status))
                // At accessibility sizes the words wrap instead of widening the row.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.spokenText)")
    }

    private func textColor(for status: TripPresentationStatus) -> Color {
        if status.kind.isDisruption { return status.color }
        return status.saysHowTheTrainRuns ? .ttTextPrimary : .ttTextSecondary
    }
}

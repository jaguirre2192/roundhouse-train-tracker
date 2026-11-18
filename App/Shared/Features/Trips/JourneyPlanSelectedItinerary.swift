import SwiftUI
import TrainTrackerCore

struct JourneyPlanSelectedItinerary: View {
    @Environment(TripLibrary.self) private var library
    let segments: [JourneyPlanSegment]
    let referenceDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if let tripID = segment.resolvedTripID, let trip = library.trip(id: tripID), segment.kind == .rail {
                    NavigationLink {
                        TripDetailView(trip: trip, selectedSegment: segment)
                    } label: {
                        row(segment, trip: trip, canOpen: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    row(segment, trip: nil, canOpen: false)
                }
                if index < segments.count - 1 {
                    Divider().padding(.leading, 36)
                }
            }
        }
    }

    private func row(_ segment: JourneyPlanSegment, trip: TrainTrip?, canOpen: Bool) -> some View {
        HStack(alignment: .top, spacing: TrainTrackerSpacing.space12) {
            Image(ttSymbol: segment.kind == .walk ? "figure.walk" : TrainTrackerSymbol.train)
                .font(.headline)
                .foregroundStyle(Color.ttTextOperational)
                .frame(width: 24)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(segment.serviceName ?? (segment.kind == .walk ? "Walk" : "Train"))
                        .font(.headline)
                        .foregroundStyle(Color.ttTextPrimary)
                    Spacer(minLength: 8)
                    if canOpen {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.ttTextSecondary)
                            .accessibilityHidden(true)
                    }
                }
                Text("\(segment.from.displayName) → \(segment.to.displayName)")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let times = times(segment, trip: trip) {
                    Text(times)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color.ttTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if segment.kind == .rail, trip == nil {
                    Text("Live tracking unavailable")
                        .font(.caption)
                        .foregroundStyle(Color.ttTextSecondary)
                } else if segment.kind == .walk, let duration = segment.duration {
                    Text("Planned walk · \(max(1, Int(ceil(duration / 60)))) min")
                        .font(.caption)
                        .foregroundStyle(Color.ttTextSecondary)
                }
            }
        }
        .padding(.vertical, TrainTrackerSpacing.space20)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func times(_ segment: JourneyPlanSegment, trip: TrainTrip?) -> String? {
        JourneyItineraryTimePresentation(segment: segment, trip: trip, referenceDate: referenceDate).text
    }
}

/// A schematic of saved passenger legs, never a map or a prediction of connection feasibility.
/// Walks, ambiguous train identity and station changes retain the detailed itinerary below.
struct JourneyTransferDiagram: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let segments: [JourneyPlanSegment]

    var body: some View {
        if let stops {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
                if dynamicTypeSize.isAccessibilitySize || stops.count > 4 {
                    vertical(stops)
                } else {
                    ViewThatFits(in: .horizontal) {
                        horizontal(stops).frame(minWidth: 320, idealWidth: 320, maxWidth: .infinity)
                        vertical(stops)
                    }
                }
                TicketPerforation()
                Text("Saved route · \(segments.count) trains · \(segments.count - 1) \(segments.count == 2 ? "change" : "changes")")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(LayoutMetrics.cardInset)
            .ticketStubStyle()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenRoute(stops))
        }
    }

    private var stops: [RailPlace]? {
        guard segments.count >= 2,
              segments.allSatisfy({ $0.kind == .rail && !$0.isStationChange && $0.from.kind == .station && $0.to.kind == .station }),
              segments.allSatisfy({ $0.resolvedTripID != nil }),
              Set(segments.compactMap(\.resolvedTripID)).count == segments.count else { return nil }
        for index in 1..<segments.count {
            guard segments[index - 1].to.id == segments[index].from.id else { return nil }
        }
        return [segments[0].from] + segments.map(\.to)
    }

    private func horizontal(_ stops: [RailPlace]) -> some View {
        HStack(alignment: .top, spacing: TrainTrackerSpacing.space8) {
            ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                VStack(spacing: TrainTrackerSpacing.space8) {
                    node(index)
                    stopLabel(stop, index: index, count: stops.count)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .backgroundPreferenceValue(JourneyTransferNodeKey.self) { anchors in
            connectingRail(anchors)
        }
    }

    private func vertical(_ stops: [RailPlace]) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space24) {
            ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                HStack(alignment: .top, spacing: TrainTrackerSpacing.space12) {
                    node(index).padding(.top, 4)
                    stopLabel(stop, index: index, count: stops.count)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .backgroundPreferenceValue(JourneyTransferNodeKey.self) { anchors in
            connectingRail(anchors)
        }
    }

    private func node(_ index: Int) -> some View {
        Circle()
            .fill(Color.ttBackgroundElevated)
            .overlay { Circle().strokeBorder(Color.ttRouteActive, lineWidth: 2) }
            .frame(width: 12, height: 12)
            .anchorPreference(key: JourneyTransferNodeKey.self, value: .center) { [index: $0] }
            .accessibilityHidden(true)
    }

    private func stopLabel(_ stop: RailPlace, index: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
            Text(stop.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ttTextBrand)
                .fixedSize(horizontal: false, vertical: true)
            if index > 0 && index < count - 1 {
                Text("Change trains")
                    .font(.caption)
                    .foregroundStyle(Color.ttTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connectingRail(_ anchors: [Int: Anchor<CGPoint>]) -> some View {
        GeometryReader { proxy in
            Path { path in
                let points = anchors.keys.sorted().compactMap { anchors[$0].map { proxy[$0] } }
                if let first = points.first {
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
            }
            .stroke(Color.ttRouteActive, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func spokenRoute(_ stops: [RailPlace]) -> String {
        let route = stops.enumerated().map { index, stop in
            index > 0 && index < stops.count - 1 ? "Change trains at \(stop.displayName)" : stop.displayName
        }.joined(separator: ". ")
        return "Saved route. \(segments.count) trains, \(segments.count - 1) \(segments.count == 2 ? "change" : "changes"). \(route)"
    }
}

private struct JourneyTransferNodeKey: PreferenceKey {
    static var defaultValue: [Int: Anchor<CGPoint>] { [:] }

    static func reduce(value: inout [Int: Anchor<CGPoint>], nextValue: () -> [Int: Anchor<CGPoint>]) {
        value.merge(nextValue(), uniquingKeysWith: { first, _ in first })
    }
}

import SwiftUI
import TrainTrackerCore

struct JourneyOptionDetailView: View {
    private let presentation: JourneyOptionPresentation
    private let segments: [JourneySegmentPresentation]
    private let attributions: [JourneySourceAttribution]

    init(option: JourneyOption) {
        presentation = JourneyOptionPresentation(option: option)
        segments = JourneySegmentPresentation.makeAll(from: option)
        attributions = JourneySourceAttribution.presentations(from: option.attributions)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                routeHeader

                ForEach(segments) { segment in
                    switch segment.kind {
                    case .rail:
                        railSegment(segment)
                    case .walk:
                        walkSegment(segment)
                    }
                }

                if !attributions.isEmpty {
                    sourceAttribution
                }
            }
            .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
            .padding(LayoutMetrics.pageInset)
        }
        .background(Color.ttBackgroundCanvas)
        .navigationTitle(JourneySearchCopy.Detail.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sourceAttribution: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            Text(JourneySearchCopy.Detail.sourceHeading)
                .font(.headline)
            Text(JourneySearchCopy.Detail.sourceQualification)
                .font(.footnote)
                .foregroundStyle(Color.ttTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(attributions) { source in
                if let destination = source.destination {
                    Link(destination: destination) {
                        Label(source.title, systemImage: source.kind == .feed ? "tram.fill" : "link")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityHint(JourneySearchCopy.Detail.sourceLinkHint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutMetrics.cardInset)
        .trainTrackerSurface(radius: TrainTrackerRadius.group)
        .accessibilityElement(children: .contain)
    }

    private var routeHeader: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space8) {
                Text(presentation.time.departure)
                Image(systemName: "arrow.right")
                    .foregroundStyle(Color.ttRouteActive)
                Text(presentation.time.arrival)
                if let day = presentation.time.arrivalDayContext {
                    Text(day)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.ttStatusDelayed)
                }
            }
            .font(.title2.weight(.bold).monospacedDigit())

            Text("\(presentation.originStation) to \(presentation.destinationStation)")
                .font(.headline)

            Text("\(presentation.time.duration) · \(presentation.changes) · \(presentation.trackability)")
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutMetrics.cardInset)
        .trainTrackerSurface(radius: TrainTrackerRadius.card)
    }

    private func railSegment(_ segment: JourneySegmentPresentation) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
            HStack(alignment: .top, spacing: TrainTrackerSpacing.space12) {
                Image(TrainTrackerSymbol.train)
                    .foregroundStyle(Color.ttActionLive)
                    .frame(width: LayoutMetrics.iconRailWidth)

                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                    Text(segment.title)
                        .font(.headline)
                    if let subtitle = segment.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Color.ttTextSecondary)
                    }
                    if segment.isCancelled {
                        Label(JourneySearchCopy.Status.cancelled, systemImage: "xmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ttStatusCancelled)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segment.calls.enumerated()), id: \.element.id) { index, call in
                    journeyCall(call, isLast: index == segment.calls.count - 1)
                }
            }

            if let trackability = segment.trackability {
                Label(
                    trackability,
                    systemImage: trackability == JourneySearchCopy.Status.trackable
                        ? "bell.badge"
                        : "bell.slash"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(
                    trackability == JourneySearchCopy.Status.trackable
                        ? Color.ttTextOperational
                        : Color.ttStatusDelayed
                )
            }
        }
        .padding(LayoutMetrics.cardInset)
        .trainTrackerSurface(radius: TrainTrackerRadius.card)
    }

    private func journeyCall(_ call: JourneyCallPresentation, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: LayoutMetrics.rowSpacing) {
            VStack(spacing: 0) {
                Circle()
                    .fill(call.isCancelled ? Color.ttStatusCancelled : Color.ttRouteActive)
                    .frame(width: 10, height: 10)
                    .padding(.top, TrainTrackerSpacing.space6)
                if !isLast {
                    Rectangle()
                        .fill(Color.ttRoutePassed)
                        .frame(width: 2, height: 42)
                }
            }
            .frame(width: LayoutMetrics.iconRailWidth)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space8) {
                    if let time = call.displayTime {
                        Text(time)
                            .font(.body.weight(.semibold).monospacedDigit())
                    }
                    Text(call.station)
                        .font(.body.weight(.medium))
                }
                if call.hasTimingUpdate, let scheduledTime = call.scheduledTime {
                    Text(JourneySearchCopy.Detail.scheduledTime(scheduledTime))
                        .font(.caption)
                        .foregroundStyle(Color.ttTextSecondary)
                }
                if let platform = call.platform {
                    Text(platform)
                        .font(.caption)
                        .foregroundStyle(Color.ttTextSecondary)
                }
                if call.isCancelled {
                    Text(JourneySearchCopy.Detail.cancelledCall)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.ttStatusCancelled)
                }
            }
            .padding(.bottom, isLast ? 0 : TrainTrackerSpacing.space12)
        }
        .accessibilityElement(children: .combine)
    }

    private func walkSegment(_ segment: JourneySegmentPresentation) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            Label(segment.title, systemImage: "figure.walk")
                .font(.headline)
            if let subtitle = segment.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
            }
            HStack(spacing: TrainTrackerSpacing.space12) {
                if let duration = segment.duration { Text(duration) }
                if let distance = segment.distance { Text(distance) }
            }
            .font(.subheadline)
            if let warning = segment.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ttStatusDelayed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutMetrics.cardInset)
        .trainTrackerSurface(color: .ttBackgroundBrandSubtle, radius: TrainTrackerRadius.group)
        .accessibilityElement(children: .combine)
    }
}

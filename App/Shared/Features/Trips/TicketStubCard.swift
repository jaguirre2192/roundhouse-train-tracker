import SwiftUI
import TrainTrackerCore

/// What a compact ticket stub shows for an upcoming journey or train.
struct TicketStubCardContent: Equatable {
    let originCode: String?
    let originName: String
    let originTitle: String
    let originScope: String?
    let destinationCode: String?
    let destinationName: String
    let destinationTitle: String
    let destinationScope: String?
    let whenText: String
    let detailText: String
    let statusText: String?
    /// Set with `statusText`, so a cancellation reads differently from a delay without colour.
    var statusIsCancellation = false

    /// Codes only when both ends have one, so the row never mixes a code with a name.
    var usesCodes: Bool { originCode != nil && destinationCode != nil }

    init(trip: TrainTrip, routeTimeZones: JourneyPlanRouteTimeZones?) {
        originCode = StationShortCode.code(for: trip.origin)
        originName = trip.origin?.displayName ?? "Origin"
        originTitle = originName
        originScope = nil
        destinationCode = StationShortCode.code(for: trip.destination)
        destinationName = trip.destination?.displayName ?? trip.headsign
        destinationTitle = destinationName
        destinationScope = nil
        if let departure = trip.stopTimes.first?.scheduledDeparture ?? trip.stopTimes.first?.expectedDeparture,
           departure.timeIntervalSinceReferenceDate.isFinite {
            // A standalone train has no plan zones; its origin station's zone, once resolved,
            // still beats the device clock.
            let zoneIdentifier = routeTimeZones?.departureTimeZoneIdentifier
                ?? StationTimeZoneResolver.cached(for: trip.origin?.id)?.identifier
            let dateText = zoneIdentifier.map {
                JourneyPlanDateTimePresentation.date(departure, timeZoneIdentifier: $0)
            } ?? departure.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            let timeText = zoneIdentifier.map {
                JourneyPlanDateTimePresentation.time(departure, timeZoneIdentifier: $0)
            } ?? departure.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: .trainTrackerTime))
            let zoneText = zoneIdentifier.flatMap(TimeZone.init(identifier:)).flatMap {
                StationBoardTimePresentation(timeZone: $0).zoneAbbreviation(at: departure)
            }
            whenText = ([dateText, timeText].joined(separator: " · ") + (zoneText.map { " \($0)" } ?? ""))
        } else {
            whenText = "Departure time unavailable"
        }
        detailText = LiveLineTicketPresentation.operatorLine(for: trip)
        let status = TripPresentationStatus(trip: trip)
        statusText = status.kind.isDisruption ? status.text : nil
        statusIsCancellation = status.kind == .cancelled
    }

    init(journey: JourneyPlanPresentation) {
        let outbound = journey.directions.first?.children.compactMap(\.trip) ?? []
        originCode = StationShortCode.code(for: outbound.first?.origin)
        originName = journey.plan.origin.displayName
        originTitle = Self.endpointTitle(for: journey.plan.origin)
        originScope = journey.plan.origin.kind == .city ? JourneySearchCopy.PlacePicker.allStations : nil
        destinationCode = StationShortCode.code(for: outbound.last?.destination)
        destinationName = journey.plan.destination.displayName
        destinationTitle = Self.endpointTitle(for: journey.plan.destination)
        destinationScope = journey.plan.destination.kind == .city ? JourneySearchCopy.PlacePicker.allStations : nil
        whenText = [journey.outboundDateText, journey.directions.first?.departureTimeText]
            .compactMap { $0 }.joined(separator: " · ")
        let kind = journey.plan.returnDirection == nil
            ? JourneySearchCopy.Plan.oneWayJourney
            : JourneySearchCopy.Plan.roundTrip
        detailText = "\(Self.sentenceCase(kind)) · \(journey.childCountText)"
        statusText = nil
    }
}

extension TicketStubCardContent {
    /// Only the app's known city-selection suffix is separated; station punctuation stays intact.
    static func endpointTitle(for place: RailPlace) -> String {
        guard place.kind == .city else { return place.displayName }
        let suffix = " — \(JourneySearchCopy.PlacePicker.allStations)"
        guard place.displayName.hasSuffix(suffix) else { return place.displayName }
        let title = String(place.displayName.dropLast(suffix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? place.displayName : title
    }

    /// Shared copy such as "ONE-WAY JOURNEY" is styled for kickers; stubs read it as a sentence.
    static func sentenceCase(_ text: String) -> String {
        let lowered = text.lowercased()
        return lowered.prefix(1).uppercased() + lowered.dropFirst()
    }
}

/// Quiet ticket paper for saved journeys: readable endpoints, a schematic rail and a facts stub.
struct TicketStubCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var disclosureWidth: CGFloat = TrainTrackerSpacing.space12

    let content: TicketStubCardContent

    var body: some View {
        // The tear line spans the card like the live ticket's, so both kinds of ticket share edges.
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space12) {
                route
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ttTextSecondary)
                    .frame(width: disclosureWidth)
                    .accessibilityHidden(true)
            }
            .padding([.horizontal, .top], LayoutMetrics.cardInset)

            TicketPerforation()

            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                Text(content.whenText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ttTextPrimary)
                Text(content.detailText)
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
                if let statusText = content.statusText {
                    Label(statusText, systemImage: content.statusIsCancellation ? "xmark.octagon.fill" : "clock.badge.exclamationmark.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(content.statusIsCancellation ? Color.ttStatusCancelled : Color.ttStatusDelayed)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding([.horizontal, .bottom], LayoutMetrics.cardInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ticketStubStyle()
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var route: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            endpoint(0, title: content.originTitle, scope: content.originScope,
                     code: content.usesCodes ? content.originCode : nil, direction: "From")
            endpoint(1, title: content.destinationTitle, scope: content.destinationScope,
                     code: content.usesCodes ? content.destinationCode : nil, direction: "To")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .backgroundPreferenceValue(TicketEndpointAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if let start = anchors[0], let end = anchors[1] {
                    Path { path in
                        path.move(to: proxy[start])
                        path.addLine(to: proxy[end])
                    }
                    .stroke(Color.ttRouteActive, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }

    private func endpoint(_ index: Int, title: String, scope: String?, code: String?, direction: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space12) {
            Circle()
                .fill(Color.ttBackgroundElevated)
                .overlay { Circle().strokeBorder(Color.ttRouteActive, lineWidth: 2) }
                .frame(width: 10, height: 10)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
                .anchorPreference(key: TicketEndpointAnchorKey.self, value: .center) { [index: $0] }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                Text(dynamicTypeSize.isAccessibilitySize ? "\(direction) \(title)" : title)
                    .font(.headline)
                    .foregroundStyle(Color.ttTextBrand)
                let context = [scope, code].compactMap { $0 }.joined(separator: " · ")
                if !context.isEmpty {
                    Text(context)
                        .font(.subheadline)
                        .foregroundStyle(Color.ttTextSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var accessibilityText: String {
        [
            "\(spokenEndpoint(content.originName, scope: content.originScope)) to \(spokenEndpoint(content.destinationName, scope: content.destinationScope))",
            content.whenText,
            content.detailText,
            content.statusText,
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private func spokenEndpoint(_ name: String, scope: String?) -> String {
        guard let scope, !name.hasSuffix(" — \(scope)") else { return name }
        return "\(name), \(scope)"
    }
}

/// Actual endpoint centers keep the decorative rail aligned as names and Dynamic Type wrap.
private struct TicketEndpointAnchorKey: PreferenceKey {
    static var defaultValue: [Int: Anchor<CGPoint>] { [:] }

    static func reduce(value: inout [Int: Anchor<CGPoint>], nextValue: () -> [Int: Anchor<CGPoint>]) {
        value.merge(nextValue(), uniquingKeysWith: { first, _ in first })
    }
}

import SwiftUI
import TrainTrackerCore

/// The small ink ticket used in a list, above journey details, or as a first train to follow.
struct CompactLineTicket<Header: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let density: LiveLineTicket.Density
    let origin: Station?
    let destination: Station?
    let summary: RouteLineSummary
    let presentation: ActiveTripCardPresentation
    let timeZoneIdentifier: (StopTime) -> String?
    let featuredTime: FeaturedCallClock?
    @ViewBuilder let header: () -> Header

    private let secondary = Color.ttTextOnBrand.opacity(0.78)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                header()
                endpoints
                if density == .compact {
                    Text(nextStep)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, LayoutMetrics.cardInset)
            .padding(.top, LayoutMetrics.cardInset)
            .padding(.bottom, density == .featured ? TrainTrackerSpacing.space6 : LayoutMetrics.cardInset)

            if density == .featured {
                TicketPerforation.onInk
                FeaturedTicketCall(presentation: presentation, clock: featuredTime)
                    .padding(.horizontal, LayoutMetrics.cardInset)
                    .padding(.top, TrainTrackerSpacing.space2)
                    .padding(.bottom, LayoutMetrics.cardInset)
            }
        }
        .liveTicketStyle()
    }

    private var endpoints: some View {
        let originCode = StationShortCode.code(for: origin)
        let destinationCode = StationShortCode.code(for: destination)
        let stacked = dynamicTypeSize.isAccessibilitySize || originCode == nil || destinationCode == nil
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TrainTrackerSpacing.space8))
            : AnyLayout(HStackLayout(spacing: TrainTrackerSpacing.space12))
        return VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
            layout {
                endpoint(origin, code: originCode, fallback: "Origin", stacked: stacked)
                    .accessibilityIdentifier("compactTicketOrigin")
                progressRail
                endpoint(destination, code: destinationCode, fallback: presentation.trip.headsign, stacked: stacked)
                    .accessibilityIdentifier("compactTicketDestination")
            }
            if density == .featured && !stacked {
                HStack(alignment: .top, spacing: TrainTrackerSpacing.space16) {
                    stationCaption(origin, code: originCode)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    stationCaption(destination, code: destinationCode)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func endpoint(_ station: Station?, code: String?, fallback: String, stacked: Bool) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
            Text(code ?? station?.displayName ?? fallback)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.ttTextOnBrand)
                .lineLimit(stacked ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
            if density == .featured && stacked {
                stationCaption(station, code: code)
            }
        }
    }

    @ViewBuilder
    private func stationCaption(_ station: Station?, code: String?) -> some View {
        if let name = station?.displayName, let code, !name.isEmpty, name.caseInsensitiveCompare(code) != .orderedSame {
            Text(name)
                .font(.footnote)
                .foregroundStyle(secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progressRail: some View {
        let lastPassed = summary.nodes.lastIndex { $0.state == .passed }
        let span = Double(max(summary.nodes.count - 1, 1))
        let fraction = summary.liveMarkerFraction ?? lastPassed.map { Double($0) / span } ?? 0
        return CompactProgressRail(progress: fraction, showsLiveMarker: summary.liveMarkerFraction != nil)
    }

    private var nextStep: String {
        guard let stop = presentation.guidanceStop else { return presentation.nextStopValue }
        var parts = ["\(presentation.nextStopLabel) \(stop.station.displayName)"]
        let time = StopTimelineTimePresentation(stop: stop, event: presentation.isBeforeBoarding ? .departure : .arrival,
                                                timeZoneIdentifier: timeZoneIdentifier(stop))
        if let text = time.timeText { parts.append(text) }
        if stop.platformGuidance(at: presentation.referenceDate) != .unavailable {
            parts.append("\(presentation.platformLabel) \(presentation.platformValue)")
        }
        return parts.joined(separator: " · ")
    }
}

/// The tear-off portion tells the rider which station the featured service is due at next.
private struct FeaturedTicketCall: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let presentation: ActiveTripCardPresentation
    let clock: FeaturedCallClock?

    var body: some View {
        if let stop = presentation.guidanceStop {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: TrainTrackerSpacing.space4))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space12))
            layout {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                    Text(callLabel)
                        .font(.caption)
                        .foregroundStyle(Color.ttTextOnBrand.opacity(0.78))
                    Text(stop.station.displayName)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                callTimeAndPlatform(stop)
            }
            .foregroundStyle(Color.ttTextOnBrand)
        } else {
            Text(presentation.nextStopValue)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.ttTextOnBrand)
        }
    }

    private var callLabel: String {
        switch JourneyTrust(card: presentation) {
        case .timetable: "Next by timetable"
        case .saved: "Next in saved times"
        case .live, .estimated: presentation.nextStopLabel
        }
    }

    private func callTimeAndPlatform(_ stop: StopTime) -> some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: TrainTrackerSpacing.space2) {
            if let text = clock?.displayText {
                Text(text)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            if case let .official(platform, source, _) = stop.platformGuidance(at: presentation.referenceDate) {
                Text(source == .scheduled ? "Scheduled \(stop.platformNoun.lowercased()) \(platform)" : "\(stop.platformNoun) \(platform)")
                    .font(.caption)
                    .foregroundStyle(Color.ttTextOnBrand.opacity(0.78))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A station-local clock where known. Until the single visible call can be located, the
/// ticket prints a labeled UTC clock. The same qualified time goes into its spoken summary.
struct FeaturedCallClock {
    struct LocatedZone {
        let stationID: RailIdentifier
        let zone: TimeZone
    }

    let timeText: String?
    let displayText: String?
    let stationToLocate: Station?

    init(stop: StopTime, boarding: Bool, suppliedZone: String?, located: LocatedZone?, cachedZone: TimeZone?,
         allowsLookup: Bool, deviceZone: TimeZone = .autoupdatingCurrent) {
        let station = stop.station
        let zone = suppliedZone.flatMap(TimeZone.init(identifier:))
            ?? (located?.stationID == station.id ? located?.zone : nil) ?? cachedZone
        let event: StopTimelineTimePresentation.Event = boarding ? .departure : .arrival
        let time = StopTimelineTimePresentation(stop: stop, event: event, timeZoneIdentifier: (zone ?? .gmt).identifier)
        guard let date = time.date, let text = time.timeText else {
            timeText = nil
            displayText = nil
            stationToLocate = nil
            return
        }
        let suffix = zone == nil ? "UTC" : JourneyPlanDateTimePresentation.zoneSuffix(
            date, timeZoneIdentifier: zone?.identifier, deviceTimeZone: deviceZone
        )
        let qualified = suffix.map { "\(text) \($0)" } ?? text
        timeText = qualified
        switch (event, time.resolvedEvent) {
        case (.arrival, .departure): displayText = "Departs \(qualified)"
        case (.departure, .arrival): displayText = "Arrives \(qualified)"
        default: displayText = qualified
        }
        let point = station.location
        let hasLocation = (-90...90).contains(point.latitude) && (-180...180).contains(point.longitude)
            && (point.latitude != 0 || point.longitude != 0)
        stationToLocate = zone == nil && allowsLookup && hasLocation ? station : nil
    }
}

/// A thin on-ink rail between two station codes, filled to `progress`, with the live marker at
/// the fill's end only when the data is live. Decorative; the ticket carries the summary.
private struct CompactProgressRail: View {
    let progress: Double
    let showsLiveMarker: Bool

    var body: some View {
        GeometryReader { proxy in
            let fillWidth = proxy.size.width * CGFloat(min(max(progress, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.ttTextOnBrand.opacity(0.24)).frame(height: 3)
                Capsule().fill(Color.ttRouteOnInk).frame(width: fillWidth, height: 3)
                if showsLiveMarker {
                    Circle()
                        .fill(Color.ttActionLiveOnInk)
                        .overlay { Circle().stroke(Color.ttBackgroundBrand, lineWidth: 2) }
                        .frame(width: 12, height: 12)
                        .offset(x: fillWidth - 6)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

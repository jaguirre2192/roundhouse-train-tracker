import SwiftUI
import TrainTrackerCore

/// Up to five stops of a journey on one line: the origin, the stop just passed, the next stop,
/// the stop after it, and the destination, plus an optional live-position marker.
struct RouteLineSummary: Equatable {
    static let maximumNodes = 5

    enum NodeState: Equatable {
        /// The train is reported to have been here.
        case passed
        /// The stop's time has gone by with nothing reporting the train there. Drawn open, and
        /// the travelled rail does not reach it.
        case due
        case next
        case upcoming
    }

    struct Node: Identifiable, Equatable {
        let id: String
        let code: String?
        let timeText: String?
        let state: NodeState
    }

    let nodes: [Node]
    /// The live marker's position along the line from 0 to 1, or nil when it must not show.
    let liveMarkerFraction: Double?

    init(
        stops: [StopTime],
        focusStopID: String?,
        phase: RailJourneyProgress.Phase,
        referenceDate: Date,
        showsLiveMarker: Bool,
        confirmedPassedStopIDs reached: Set<String> = [],
        isArrivalConfirmed arrived: Bool = false,
        timeZoneIdentifier: (StopTime) -> String? = { _ in nil }
    ) {
        // Without evidence nothing is confirmed: the clock alone never fills a dot.
        func earlier(_ stop: StopTime, isLast: Bool) -> NodeState {
            reached.contains(stop.id) || (arrived && isLast) || (arrived && ended) ? .passed : .due
        }
        let focusIndex = focusStopID.flatMap { id in stops.firstIndex { $0.id == id } }
        let ended = phase == .ended
        let anchor = focusIndex ?? (ended ? max(stops.count - 1, 0) : 0)
        let indices = Self.selectedIndices(count: stops.count, anchor: anchor)

        nodes = indices.map { index in
            let stop = stops[index]
            let state: NodeState
            if ended {
                state = earlier(stop, isLast: index == stops.count - 1)
            } else if let focusIndex {
                state = index < focusIndex ? earlier(stop, isLast: false) : (index == focusIndex ? .next : .upcoming)
            } else {
                state = .upcoming
            }
            let time = StopTimelineTimePresentation(
                stop: stop,
                event: index == 0 ? .departure : .arrival,
                timeZoneIdentifier: timeZoneIdentifier(stop)
            )
            return Node(
                id: stop.id,
                code: StationShortCode.code(for: stop.station),
                timeText: time.date.map { Self.compactTime($0, timeZoneIdentifier: timeZoneIdentifier(stop)) },
                state: state
            )
        }

        liveMarkerFraction = Self.markerFraction(
            stops: stops,
            indices: indices,
            focusIndex: focusIndex,
            // The marker is an estimate between two stops; it is only placed once the train is
            // reported past the stop behind it.
            isLive: showsLiveMarker && phase == .underway
                && (focusIndex.map { $0 > 0 && reached.contains(stops[$0 - 1].id) } ?? false),
            referenceDate: referenceDate
        )
    }

    /// Hours and minutes without the day period ("4:04", or "16:04" where the locale uses a
    /// 24-hour clock), so five times fit on one line. Full times appear elsewhere on the ticket.
    static func compactTime(_ date: Date, timeZoneIdentifier: String?, locale: Locale = .trainTrackerTime) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale)
            .hour(.defaultDigits(amPM: .omitted))
            .minute(.twoDigits)
        if let timeZoneIdentifier, let zone = TimeZone(identifier: timeZoneIdentifier) {
            style.timeZone = zone
        }
        return date.formatted(style)
    }

    /// Always keeps both ends and the stops either side of the anchor, then fills the remaining
    /// slots with the stops nearest the anchor.
    static func selectedIndices(count: Int, anchor: Int) -> [Int] {
        guard count > maximumNodes else { return Array(0..<count) }
        let valid = 0..<count
        var picked: Set<Int> = [0, count - 1]
        for index in [anchor - 1, anchor, anchor + 1] where valid.contains(index) {
            picked.insert(index)
        }
        var distance = 2
        while picked.count < maximumNodes {
            for index in [anchor - distance, anchor + distance]
            where valid.contains(index) && picked.count < maximumNodes {
                picked.insert(index)
            }
            distance += 1
        }
        return picked.sorted()
    }

    /// The marker sits between the stop just passed and the next stop, placed by elapsed time
    /// and kept clear of both dots.
    private static func markerFraction(
        stops: [StopTime],
        indices: [Int],
        focusIndex: Int?,
        isLive: Bool,
        referenceDate: Date
    ) -> Double? {
        guard isLive, indices.count > 1, let focusIndex, focusIndex > 0,
              let focusSlot = indices.firstIndex(of: focusIndex),
              let previousSlot = indices.firstIndex(of: focusIndex - 1) else { return nil }
        let previous = stops[focusIndex - 1]
        let next = stops[focusIndex]
        var progress = 0.5
        if let departed = previous.expectedDeparture ?? previous.scheduledDeparture,
           let arriving = next.expectedArrival ?? next.scheduledArrival,
           arriving > departed {
            progress = referenceDate.timeIntervalSince(departed) / arriving.timeIntervalSince(departed)
        }
        let clamped = min(max(progress, 0.2), 0.8)
        let span = Double(indices.count - 1)
        return (Double(previousSlot) + clamped * Double(focusSlot - previousSlot)) / span
    }
}

/// Draws a `RouteLineSummary` on one horizontal rail. Stops are spaced evenly with every label
/// centred on its dot, and the rail runs through the dots' centres. At accessibility text sizes
/// it becomes a short vertical list. Hidden from VoiceOver: the ticket carries the summary.
struct RouteLineSummaryView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var codeRowHeight: CGFloat = 14
    @ScaledMetric(relativeTo: .caption) private var timeRowHeight: CGFloat = 16

    /// Colours for the line on white paper or on the ink live ticket.
    struct Palette {
        let passedRail: Color
        let upcomingRail: Color
        let nextRing: Color
        /// Kept at or above the 3:1 indicator floor against `surface`.
        let upcomingRing: Color
        let live: Color
        let primaryText: Color
        let secondaryText: Color
        /// The ticket colour behind the line, used to fill open dots and ring the live marker.
        let surface: Color

        static let standard = Palette(
            passedRail: .ttRouteActive,
            upcomingRail: .ttRoutePassed,
            nextRing: .ttTextPrimary,
            upcomingRing: .ttTextSecondary,
            live: .ttActionLive,
            primaryText: .ttTextPrimary,
            secondaryText: .ttTextSecondary,
            surface: .ttBackgroundElevated
        )

        static let onInk = Palette(
            passedRail: .ttRouteOnInk,
            upcomingRail: Color.ttTextOnBrand.opacity(0.24),
            nextRing: .ttTextOnBrand,
            upcomingRing: Color.ttTextOnBrand.opacity(0.7),
            live: .ttActionLiveOnInk,
            primaryText: .ttTextOnBrand,
            secondaryText: Color.ttTextOnBrand.opacity(0.72),
            surface: .ttBackgroundBrand
        )
    }

    let summary: RouteLineSummary
    var palette: Palette = .standard
    /// On a journey resting over its map: a tap on a stop, or a slide along the line, moves
    /// the map there.
    var linksToMap = false
    @Environment(JourneyMapLink.self) private var mapLink: JourneyMapLink?

    private let railThickness: CGFloat = 4
    private let nodeRowHeight: CGFloat = 18
    private let rowGap = TrainTrackerSpacing.space6
    private let endDotRadius: CGFloat = 7
    /// The live marker keeps at least this much space between its centre and either dot.
    private let markerClearance: CGFloat = 26

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            verticalList
        } else {
            horizontalLine
        }
    }

    private var horizontalLine: some View {
        let railY = codeRowHeight + rowGap + nodeRowHeight / 2
        let height = codeRowHeight + rowGap * 2 + nodeRowHeight + timeRowHeight

        return GeometryReader { proxy in
            let count = summary.nodes.count
            let width = proxy.size.width
            let firstX = endDotRadius
            let lastX = width - endDotRadius
            let step = count > 1 ? (lastX - firstX) / CGFloat(count - 1) : 0
            let labelWidth = count > 1 ? step : width
            let x: (Int) -> CGFloat = { firstX + CGFloat($0) * step }
            let markerX = summary.liveMarkerFraction.map { fraction in
                clampedMarkerX(firstX + CGFloat(fraction) * (lastX - firstX), step: step, firstX: firstX)
            }

            ZStack(alignment: .topLeading) {
                if count > 1 {
                    rail(from: firstX, to: lastX, y: railY, color: palette.upcomingRail)
                    if let passedEnd = markerX ?? lastPassedX(x: x) {
                        rail(from: firstX, to: passedEnd, y: railY, color: palette.passedRail)
                    }
                }

                ForEach(Array(summary.nodes.enumerated()), id: \.element.id) { index, node in
                    let placement = labelPlacement(index: index, count: count, x: x(index), width: width, labelWidth: labelWidth)

                    Text(node.code ?? "")
                        .font(.caption2.weight(node.state == .next ? .bold : .semibold))
                        .foregroundStyle(node.state == .passed || node.state == .due ? palette.secondaryText : palette.primaryText)
                        .lineLimit(1)
                        .frame(width: labelWidth, height: codeRowHeight, alignment: placement.alignment)
                        .position(x: placement.centerX, y: codeRowHeight / 2)

                    dot(for: node.state)
                        .position(x: x(index), y: railY)

                    // Times turn over like a departure board when live data moves them.
                    FlapText(
                        node.timeText ?? "", font: .caption,
                        color: node.state == .passed || node.state == .due ? palette.secondaryText : palette.primaryText,
                        weight: node.state == .next ? .bold : .regular
                    )
                        .lineLimit(1)
                        .frame(width: labelWidth, height: timeRowHeight, alignment: placement.alignment)
                        .position(x: placement.centerX, y: height - timeRowHeight / 2)
                }

                if let markerX {
                    Circle()
                        .fill(palette.live)
                        .frame(width: 18, height: 18)
                        .overlay { Circle().stroke(palette.surface, lineWidth: 3) }
                        .position(x: markerX, y: railY)
                }

                if linksToMap, let mapLink {
                    let originX = proxy.frame(in: .global).minX
                    if let scrubX = mapLink.scrubX, mapLink.focus != nil {
                        // Where a slide along the line is, or was left.
                        focusRing.position(x: scrubX - originX, y: railY)
                    } else if let id = mapLink.focus?.stopID, let index = summary.nodes.firstIndex(where: { $0.id == id }) {
                        focusRing.position(x: x(index), y: railY)
                    }
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                guard linksToMap else { return }
                mapLink?.registerLine(frame: frame, nodes: summary.nodes.enumerated().map { index, node in
                    JourneyMapLink.LineNode(id: node.id, x: frame.minX + x(index))
                })
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
        .contentShape(.rect)
        .onTapGesture(coordinateSpace: .global) { mapLink?.tap(at: $0) }
        .gesture(HorizontalRouteScrubGesture(
            isEnabled: linksToMap && (mapLink?.scrubsDirectly ?? false),
            changed: { start, location in _ = mapLink?.scrub(start: start, location: location) },
            ended: { mapLink?.endScrub() }
        ))
        .allowsHitTesting(linksToMap && mapLink != nil)
        .sensoryFeedback(.selection, trigger: linksToMap ? mapLink?.focus?.stopID : nil)
    }

    private var focusRing: some View {
        Circle()
            .fill(palette.surface)
            .overlay { Circle().strokeBorder(palette.primaryText, lineWidth: 3.5) }
            .frame(width: 22, height: 22)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }

    /// End labels align to the line's outer edges so they share the ticket's content edges; the
    /// others centre on their dots. Every label is one step wide, so neighbours never overlap.
    private func labelPlacement(
        index: Int, count: Int, x: CGFloat, width: CGFloat, labelWidth: CGFloat
    ) -> (centerX: CGFloat, alignment: Alignment) {
        if count > 1, index == 0 { return (labelWidth / 2, .leading) }
        if count > 1, index == count - 1 { return (width - labelWidth / 2, .trailing) }
        return (x, .center)
    }

    /// Keeps the marker clear of the dots on either side of its segment, centring it when the
    /// segment is too short for the full clearance.
    private func clampedMarkerX(_ rawX: CGFloat, step: CGFloat, firstX: CGFloat) -> CGFloat {
        guard step > 0 else { return rawX }
        let segment = floor((rawX - firstX) / step)
        let start = firstX + segment * step
        let end = start + step
        guard end - start > markerClearance * 2 else { return (start + end) / 2 }
        return min(max(rawX, start + markerClearance), end - markerClearance)
    }

    /// Where the teal passed segment ends without a live marker: the last passed stop. Nil when
    /// nothing has been passed.
    private func lastPassedX(x: (Int) -> CGFloat) -> CGFloat? {
        guard let lastPassed = summary.nodes.lastIndex(where: { $0.state == .passed }), lastPassed > 0 else {
            return nil
        }
        return x(lastPassed)
    }

    private func rail(from start: CGFloat, to end: CGFloat, y: CGFloat, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: max(end - start, 0), height: railThickness)
            .position(x: (start + end) / 2, y: y)
    }

    @ViewBuilder
    private func dot(for state: RouteLineSummary.NodeState) -> some View {
        switch state {
        case .passed:
            Circle()
                .fill(palette.passedRail)
                .frame(width: 12, height: 12)
        case .next:
            Circle()
                .fill(palette.surface)
                .overlay { Circle().strokeBorder(palette.nextRing, lineWidth: 3) }
                .frame(width: 14, height: 14)
        case .upcoming:
            Circle()
                .fill(palette.surface)
                .overlay { Circle().strokeBorder(palette.upcomingRing, lineWidth: 2) }
                .frame(width: 12, height: 12)
        case .due:
            Circle()
                .fill(palette.surface)
                .overlay { Circle().strokeBorder(palette.passedRail, lineWidth: 2) }
                .frame(width: 12, height: 12)
        }
    }

    /// The stop just passed, the next stop and everything after it, one per row.
    private var verticalList: some View {
        let lastPassed = summary.nodes.last { $0.state == .passed }
        let visible = (lastPassed.map { [$0] } ?? []) + summary.nodes.filter { $0.state != .passed }
        return VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            ForEach(visible) { node in
                HStack(alignment: .center, spacing: TrainTrackerSpacing.space12) {
                    dot(for: node.state)
                        .frame(width: LayoutMetrics.iconRailWidth)
                    Text(node.code ?? "")
                        .font(.body.weight(node.state == .next ? .bold : .semibold))
                    Spacer(minLength: TrainTrackerSpacing.space8)
                    Text(node.timeText ?? "")
                        .font(.body)
                        .monospacedDigit()
                }
                .foregroundStyle(node.state == .passed || node.state == .due ? palette.secondaryText : palette.primaryText)
            }
        }
        .accessibilityHidden(true)
    }
}

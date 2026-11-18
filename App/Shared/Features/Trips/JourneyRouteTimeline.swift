import SwiftUI
import TrainTrackerCore

struct JourneyRouteTimeline: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expansion = JourneyRouteOutline.Expansion.compact
    @State private var clockStopID: StopTime.ID?
    @Namespace private var stopsRotor
    let presentation: JourneyExperiencePresentation
    /// Set where the journey rests over its map: choosing a stop shows it there.
    var selectedStopID: String? = nil
    var select: ((StopTime) -> Void)? = nil

    private struct RouteScope: Equatable {
        let tripID: RailIdentifier
        let serviceDate: Date
        let segmentID: String?
    }

    var body: some View {
        let scope = RouteScope(tripID: presentation.trip.id, serviceDate: presentation.trip.serviceDate,
                               segmentID: presentation.selectedSegment?.id)
        timeline.onChange(of: scope) {
            expansion = .compact
            clockStopID = nil
        }
    }

    @ViewBuilder
    private var timeline: some View {
        let stops = presentation.progress.stops
        if !stops.isEmpty {
            let clocks = RouteClockGuide(stops: stops, zones: presentation.timeZones)
            let outline = JourneyRouteOutline(stops: stops, focusID: presentation.progress.focusStop?.id,
                                             expansion: expansion, pinned: clocks.changes)
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space20) {
                heading(outline)

                VStack(spacing: 0) {
                    ForEach(outline.rows) { item in
                        switch item {
                        case .stop(let stop):
                            let comparison = clocks.comparisons[stop.id]
                            if clocks.changes.contains(stop.id), let comparison {
                                RouteClockMark(comparison: comparison, expanded: clockStopID == stop.id) {
                                    toggleClock(stop)
                                }
                            }
                            row(stop, comparesClocks: comparison != nil)
                                .accessibilityRotorEntry(id: stop.id, in: stopsRotor)
                            if clockStopID == stop.id, let comparison { RouteStationClocks(comparison: comparison) }
                        case .gap(let gap):
                            StopTimelineGapRow(gap: gap) {
                                setExpansion(expansion.opening(gap, remainingGaps: outline.gapCount))
                            }
                        }
                    }
                }
                // VoiceOver users jump stop to stop, with the next stop named as such.
                .accessibilityRotor("Stops") {
                    ForEach(outline.visibleStops) { stop in
                        AccessibilityRotorEntry(Text(rotorLabel(stop)), id: stop.id, in: stopsRotor)
                    }
                }

                if presentation.selectedSegment == nil {
                    Text("Showing this train’s route. Your ticket may cover only part of it.")
                        .font(.caption)
                        .foregroundStyle(Color.ttTextSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setExpansion(_ next: JourneyRouteOutline.Expansion) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { expansion = next }
    }

    @ViewBuilder
    private func heading(_ outline: JourneyRouteOutline) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                routeTitle
                stopsButton(outline)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space12) {
                routeTitle
                Spacer(minLength: TrainTrackerSpacing.space8)
                stopsButton(outline)
            }
        }
    }

    private var routeTitle: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
            Text(presentation.selectedSegment == nil ? "Train Route" : "Your Route")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.ttTextPrimary)
                .accessibilityAddTraits(.isHeader)
            if select != nil {
                Text("Choose a stop to see it on the map")
                    .font(.footnote)
                    .foregroundStyle(Color.ttTextSecondary)
            }
        }
    }

    @ViewBuilder
    private func stopsButton(_ outline: JourneyRouteOutline) -> some View {
        // A single closed stretch already offers the only disclosure needed.
        if outline.canCollapse || outline.gapCount > 1 {
            Button(outline.canCollapse ? "Fewer stops" : "All \(presentation.progress.stops.count) stops") {
                setExpansion(outline.canCollapse ? .compact : .all)
            }
            .font(.subheadline.weight(.medium))
            .frame(minHeight: 44)
            .accessibilityIdentifier("routeStopOverview")
        }
    }

    @ViewBuilder
    private func row(_ stop: StopTime, comparesClocks: Bool) -> some View {
        let row = StopTimelineRow(
            stop: stop,
            isNext: stop.id == presentation.progress.focusStop?.id,
            isLast: stop.id == presentation.progress.stops.last?.id,
            isFirst: stop.id == presentation.progress.stops.first?.id,
            timeZoneIdentifier: presentation.timeZones.timeZoneIdentifier(for: stop),
            isEarlier: isEarlier(stop),
            stateOverride: stateOverride(stop),
            referenceDate: presentation.referenceDate,
            isReachConfirmed: isReachConfirmed(stop),
            nextStopRole: presentation.progress.nextStopRole,
            compareClocks: comparesClocks ? { toggleClock(stop) } : nil,
            selectOnMap: select.map { action in { action(stop) } },
            mapSelected: selectedStopID == stop.id
        )
        if comparesClocks {
            row.background { selectedStopBackground(stop) }
        } else if let select {
            Button { select(stop) } label: {
                row
                    .contentShape(.rect)
                    .background { selectedStopBackground(stop) }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selectedStopID == stop.id ? .isSelected : [])
            .accessibilityHint("Shows this stop on the map")
            .accessibilityIdentifier("routeStop-\(stop.id)")
        } else {
            row
        }
    }

    @ViewBuilder
    private func selectedStopBackground(_ stop: StopTime) -> some View {
        if selectedStopID == stop.id {
            RoundedRectangle(cornerRadius: TrainTrackerRadius.icon, style: .continuous)
                .fill(Color.ttBackgroundBrand.opacity(0.07))
                .padding(.horizontal, -TrainTrackerSpacing.space8)
                .padding(.top, -TrainTrackerSpacing.space8)
                .padding(.bottom, TrainTrackerSpacing.space8)
        }
    }

    private func toggleClock(_ stop: StopTime) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            clockStopID = clockStopID == stop.id ? nil : stop.id
        }
    }

    private func rotorLabel(_ stop: StopTime) -> String {
        if stop.isCancelled { return "\(stop.station.displayName), canceled" }
        if stop.id == presentation.progress.focusStop?.id { return "\(stop.station.displayName), \(presentation.progress.nextStopRole.lowercased())" }
        return stop.station.displayName
    }

    /// An earlier stop is drawn as reached only when something reports the train there. The
    /// next stop's approach is drawn as travelled only when the stop before it was reached.
    private func isReachConfirmed(_ stop: StopTime) -> Bool {
        if isEarlier(stop) { return ArrivalEvidence.hasReached(stop, progress: presentation.progress) }
        if stop.id == presentation.progress.focusStop?.id,
           let previous = presentation.progress.stops.last(where: { $0.sequence < stop.sequence }) {
            return ArrivalEvidence.hasReached(previous, progress: presentation.progress)
        }
        return true
    }

    private func isEarlier(_ stop: StopTime) -> Bool {
        if presentation.progress.phase == .ended { return true }
        guard let focus = presentation.progress.focusStop else { return false }
        return stop.sequence < focus.sequence
    }

    private func stateOverride(_ stop: StopTime) -> String? {
        if stop.isCancelled { return nil }
        if stop.id == presentation.progress.stops.first?.id,
           presentation.progress.phase == .upcoming || presentation.progress.phase == .departureSoon {
            return "Departure"
        }
        if stop.id == presentation.progress.stops.last?.id { return "Destination" }
        return nil
    }
}

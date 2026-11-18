import SwiftUI
import TrainTrackerCore

struct RouteClockMark: View {
    let comparison: RouteClockComparison
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            StopTimelineColumns(alignment: .center) {
                Color.clear.frame(height: 1)
            } rail: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.ttTextOperational)
            } detail: {
                HStack(spacing: TrainTrackerSpacing.space6) {
                    Text("Clocks \(comparison.shift)")
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Color.ttActionTint)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clocks \(comparison.shift). Compare station times")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("routeClockChange")
    }
}

struct RouteStationClocks: View {
    let comparison: RouteClockComparison

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            Text(comparison.event)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ttTextSecondary)
            reading(comparison.current, primary: true)
            Divider()
            reading(comparison.previous, primary: false)
        }
        .padding(TrainTrackerSpacing.space12)
        .background(Color.ttBackgroundBrandSubtle, in: RoundedRectangle(cornerRadius: TrainTrackerRadius.icon))
        .padding(.bottom, TrainTrackerSpacing.space12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routeStationClocks")
    }

    private func reading(_ station: RouteClockComparison.StationClock, primary: Bool) -> some View {
        let time = JourneyPlanDateTimePresentation.time(comparison.instant, timeZoneIdentifier: station.zone.identifier)
        let date = JourneyPlanDateTimePresentation.date(comparison.instant, timeZoneIdentifier: station.zone.identifier)
        return HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space12) {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                Text(station.name).font(.subheadline.weight(.semibold))
                Text(date).font(.caption).foregroundStyle(Color.ttTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(time)
                .font(.headline.monospacedDigit())
                .fixedSize()
        }
        .foregroundStyle(primary ? Color.ttTextPrimary : Color.ttTextSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(primary ? "stationClockArrival" : "stationClockPrevious")
    }
}

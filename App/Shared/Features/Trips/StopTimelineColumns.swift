import SwiftUI

/// Stops and folded stretches share an identical clock gutter and rail at every text size.
struct StopTimelineColumns<Time: View, Rail: View, Detail: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var timeWidth: CGFloat = 72
    var alignment: VerticalAlignment = .top
    @ViewBuilder let time: () -> Time
    @ViewBuilder let rail: () -> Rail
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        HStack(alignment: alignment, spacing: 0) {
            if !dynamicTypeSize.isAccessibilitySize {
                time().frame(width: timeWidth, alignment: .trailing)
            }
            rail().frame(width: 36)
            detail()
        }
    }
}

/// A dotted continuation marks omitted calls without implying passage through them.
struct StopTimelineGapRow: View {
    let gap: JourneyRouteOutline.Gap
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            StopTimelineColumns(alignment: .center) {
                Color.clear.frame(height: 1)
            } rail: {
                Canvas { context, size in
                    var path = Path()
                    path.move(to: CGPoint(x: size.width / 2, y: 0))
                    path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                    context.stroke(path, with: .color(.ttRoutePassed),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 5]))
                }
                .accessibilityHidden(true)
            } detail: {
                HStack(spacing: TrainTrackerSpacing.space6) {
                    Text(gap.count == 1 ? "1 intermediate stop" : "\(gap.count) intermediate stops")
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.ttActionTint)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(gap.count == 1 ? "Show 1 intermediate stop" : "Show \(gap.count) intermediate stops")
        .accessibilityValue("Between \(gap.from.station.displayName) and \(gap.to.station.displayName)")
        .accessibilityIdentifier("routeStopGap-\(gap.from.id)-\(gap.to.id)")
    }
}

import SwiftUI
import TrainTrackerCore

/// The train: an ink marker carrying the train symbol, ringed in the colour of how its position
/// is known. A live position breathes; nothing else on the map moves.
struct VehicleMapMarker: View {
    /// Grows with text size, within what still reads as a badge on the marker.
    @ScaledMetric(relativeTo: .caption2) private var badgeSize: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: TrainPositionStatus
    let nearbyNextStopName: String?
    /// The journey has not been checked this session: the position is the last one saved, so
    /// it is not offered as live however recent its timestamp.
    var isSaved = false
    /// The marker has been carried along the track past the last reported position.
    var isBetweenReports = false

    var body: some View {
        Image(TrainTrackerSymbol.train)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.ttTextOnBrand)
            .frame(width: 36, height: 36)
            .background(Color.ttBackgroundBrand, in: Circle())
            .overlay { Circle().strokeBorder(statusColor, lineWidth: 3) }
            .padding(3)
            .background(Color.ttBackgroundElevated, in: Circle())
            .background {
                if status == .live, !isSaved, !reduceMotion {
                    Circle()
                        .stroke(statusColor, lineWidth: 2)
                        .phaseAnimator([false, true]) { ring, expanded in
                            ring.scaleEffect(expanded ? 1.9 : 1).opacity(expanded ? 0 : 0.7)
                        } animation: { expanded in
                            expanded ? .easeOut(duration: 1.8) : .linear(duration: 0.01)
                        }
                }
            }
            .shadow(color: Color.ttBackgroundBrand.opacity(0.35), radius: 6, y: 3)
            .overlay(alignment: .top) {
                sourceBadge
                    .offset(y: -15)
            }
            .overlay(alignment: .bottom) {
                if let nearbyNextStopName {
                    MapCallout(text: "Next · \(nearbyNextStopName)")
                        .offset(y: 25)
                }
            }
            .accessibilityHidden(true)
    }

    private var sourceBadge: some View {
        Text(markerLabel)
            .font(.system(size: min(badgeSize, 15), weight: .bold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(Color.ttTextOnBrand)
            .background(statusColor, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.ttBackgroundElevated, lineWidth: 1.5) }
    }

    private var markerLabel: String {
        if isSaved, status == .live || status == .recent { return "SAVED" }
        if isBetweenReports, status == .live || status == .recent { return "EST" }
        return status.markerLabel
    }

    private var statusColor: Color {
        if isSaved, status == .live || status == .recent { return .ttTextSecondary }
        if isBetweenReports, status == .live || status == .recent { return .ttRouteActive }
        switch status {
        case .live, .recent: return .ttActionLive
        case .stale: return .ttStatusDelayed
        case .estimated: return .ttRouteActive
        case .unavailable: return .ttTextSecondary
        }
    }
}

/// A small label on the elevated surface, used beside the train and the next stop.
private struct MapCallout: View {
    let text: String
    var maximumWidth: CGFloat? = nil

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(maximumWidth == nil ? 1 : nil)
            .fixedSize(horizontal: maximumWidth == nil, vertical: true)
            .frame(maxWidth: maximumWidth)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(Color.ttTextPrimary)
            .background(Color.ttBackgroundElevated, in: Capsule())
            .overlay { Capsule().stroke(Color.ttBorderSubtle, lineWidth: TrainTrackerStroke.subtle) }
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}

struct MapStop: Identifiable {
    enum Role {
        case origin
        case passed
        case next
        case destination
    }

    let stop: StopTime
    let role: Role

    var id: String { stop.id }

    var accessibilityLabel: String {
        switch role {
        case .origin: "Trip origin, \(stop.station.displayName)"
        case .passed: "Most recently passed, \(stop.station.displayName)"
        case .next: "Next stop, \(stop.station.displayName)"
        case .destination: "Trip destination, \(stop.station.displayName)"
        }
    }

    /// Every marker centres its node on the station; plates and callouts hang off it.
    var annotationAnchor: UnitPoint { .center }
}

/// A station drawn as the ticket draws its stops: travelled is a filled teal node, the next
/// stop and the destination are open rings. The two ends carry their station code on an ink
/// plate, like the codes on the ticket. Never a train: only the vehicle marker uses that symbol.
struct MapStopMarker: View {
    @Environment(\.layoutDirection) private var layoutDirection
    let item: MapStop
    /// The callout grows toward the route's middle; the node still owns the annotation bounds.
    var calloutExtendsLeft = false

    var body: some View {
        node
            .shadow(color: Color.ttBackgroundBrand.opacity(0.25), radius: 3, y: 1)
            .overlay(alignment: plateAlignment) {
                if let code = plateCode {
                    Text(code)
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .foregroundStyle(Color.ttTextOnBrand)
                        .background(Color.ttBackgroundBrand, in: Capsule())
                        .overlay { Capsule().strokeBorder(Color.ttBackgroundElevated, lineWidth: 1.5) }
                        .shadow(color: Color.ttBackgroundBrand.opacity(0.3), radius: 3, y: 1)
                        .offset(y: -25)
                }
            }
            .overlay(alignment: calloutAlignment) {
                if item.role == .next {
                    MapCallout(text: "Next stop · \(item.stop.station.displayName)", maximumWidth: 220)
                        // A wrapped label grows below the node instead of covering its coordinate.
                        .alignmentGuide(.bottom) { $0[.top] }
                        .offset(y: TrainTrackerSpacing.space8)
                }
            }
            .accessibilityHidden(true)
    }

    private var usesTrailingEdge: Bool { calloutExtendsLeft == (layoutDirection == .leftToRight) }

    private var calloutAlignment: Alignment { usesTrailingEdge ? .bottomTrailing : .bottomLeading }

    private var plateAlignment: Alignment {
        // Full station names grow into the map pane. A short station code fits above its node.
        guard plateCode == item.stop.station.displayName else { return .top }
        return usesTrailingEdge ? .topTrailing : .topLeading
    }

    @ViewBuilder
    private var node: some View {
        switch item.role {
        case .origin:
            ring(fill: .ttRouteActive, stroke: .ttBackgroundElevated, size: 18, lineWidth: 3.5)
        case .passed:
            ring(fill: .ttRouteActive, stroke: .ttBackgroundElevated, size: 12, lineWidth: 2.5)
        case .next:
            ring(fill: .ttBackgroundElevated, stroke: .ttRouteActive, size: 18, lineWidth: 4.5)
        case .destination:
            ring(fill: .ttBackgroundElevated, stroke: .ttBackgroundBrand, size: 18, lineWidth: 4.5)
        }
    }

    private func ring(fill: Color, stroke: Color, size: CGFloat, lineWidth: CGFloat) -> some View {
        Circle()
            .fill(fill)
            .overlay { Circle().strokeBorder(stroke, lineWidth: lineWidth) }
            .frame(width: size, height: size)
            // A hairline keeps a white ring visible on pale parts of the map.
            .overlay { Circle().strokeBorder(Color.ttBackgroundBrand.opacity(0.25), lineWidth: 0.5) }
    }

    private var plateCode: String? {
        guard item.role == .origin || item.role == .destination else { return nil }
        return StationShortCode.code(for: item.stop.station) ?? item.stop.station.displayName
    }
}

/// The place the rider asked to see: an ink ring on the track, with the stop's name and time
/// on an ink plate when it rests on a stop.
struct MapFocusMarker: View {
    let caption: String?

    var body: some View {
        Circle()
            .fill(Color.ttBackgroundElevated)
            .overlay { Circle().strokeBorder(Color.ttBackgroundBrand, lineWidth: 5) }
            .frame(width: 22, height: 22)
            .shadow(color: Color.ttBackgroundBrand.opacity(0.3), radius: 4, y: 1)
            .overlay(alignment: .top) {
                if let caption {
                    Text(caption)
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(Color.ttTextOnBrand)
                        .background(Color.ttBackgroundBrand, in: Capsule())
                        .overlay { Capsule().strokeBorder(Color.ttBackgroundElevated, lineWidth: 1.5) }
                        .shadow(color: Color.ttBackgroundBrand.opacity(0.3), radius: 4, y: 1)
                        .offset(y: -34)
                        .transition(.opacity)
                }
            }
            .accessibilityHidden(true)
    }
}

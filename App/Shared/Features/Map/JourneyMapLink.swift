import CoreLocation
import Observation
import SwiftUI
import TrainTrackerCore

/// A place on the journey the rider asked the map to show.
enum JourneyMapFocus: Equatable {
    /// A stop chosen from the list or the ticket, by its stop-time id. The map goes in close.
    case stop(String)
    /// Part of the way from one stop to another while sliding along the ticket's line.
    /// `t` runs from 0 at the first stop to 1 at the second.
    case between(String, String, t: Double)

    /// The stop the focus rests on, when it rests on one.
    var stopID: String? {
        switch self {
        case let .stop(id): id
        case let .between(first, _, t) where t <= 0: first
        case let .between(_, second, t) where t >= 1: second
        case .between: nil
        }
    }

    /// Where the focus is, following the track when the route's line is known.
    func coordinate(in trip: TrainTrip, path: RoutePath?) -> CLLocationCoordinate2D? {
        func place(_ id: String) -> CLLocationCoordinate2D? {
            trip.stopTimes.first { $0.id == id }?.station.mapCoordinate
        }
        switch self {
        case let .stop(id):
            return place(id)
        case let .between(first, second, t):
            guard let from = place(first), let to = place(second) else { return nil }
            let t = min(max(t, 0), 1)
            if t == 0 { return from }
            if t == 1 { return to }
            if let path, path.length > 0 {
                let start = path.projection(of: from).distance, end = path.projection(of: to).distance
                return path.coordinate(at: start + (end - start) * t)
            }
            return CLLocationCoordinate2D(
                latitude: from.latitude + (to.latitude - from.latitude) * t,
                longitude: from.longitude + (to.longitude - from.longitude) * t
            )
        }
    }
}

/// Ties a journey's panel to its map. The stop list and the ticket's route line set `focus`;
/// the map moves its camera to it. The ticket's line also registers where it is on screen, so
/// the panel's own drag can hand a sideways slide along the line over as a scrub.
@MainActor
@Observable
final class JourneyMapLink {
    struct LineNode: Equatable {
        let id: String
        /// The stop's dot on the ticket's line, in global coordinates.
        let x: CGFloat
    }

    var focus: JourneyMapFocus? {
        didSet {
            // A focus set any other way than by sliding has no place of its own on the line.
            if !isSettingFromSlide { scrubX = nil }
        }
    }
    /// Where a slide along the line is, or was left, in global coordinates.
    private(set) var scrubX: CGFloat?
    private(set) var isScrubbing = false
    /// True where the journey floats beside the map in a panel of its own. There is no panel
    /// drag to hand a slide over, so the ticket's line takes the drag itself.
    var scrubsDirectly = false
    @ObservationIgnored private var isSettingFromSlide = false
    @ObservationIgnored private(set) var lineFrame = CGRect.zero
    @ObservationIgnored private(set) var nodes: [LineNode] = []

    /// A slide snaps to a stop within this distance of its dot.
    static let snapDistance: CGFloat = 9

    func registerLine(frame: CGRect, nodes: [LineNode]) {
        lineFrame = frame
        self.nodes = nodes
    }

    /// Takes a sideways drag that began on the line. Returns false when the drag is not the
    /// line's to take, so the panel can treat it as its own.
    func scrub(start: CGPoint, location: CGPoint) -> Bool {
        guard let first = nodes.first, let last = nodes.last, nodes.count > 1 else { return false }
        if !isScrubbing, !lineFrame.insetBy(dx: -12, dy: -16).contains(start) { return false }
        let x = min(max(location.x, first.x), last.x)
        isScrubbing = true
        isSettingFromSlide = true
        focus = Self.focus(at: x, nodes: nodes)
        isSettingFromSlide = false
        scrubX = x
        return true
    }

    /// The finger lifted. The map and the mark on the line stay where it left them.
    func endScrub() {
        isScrubbing = false
    }

    /// A tap on the line goes to the nearest stop, when one is within reach of the finger.
    func tap(at point: CGPoint) {
        guard let nearest = nodes.min(by: { abs($0.x - point.x) < abs($1.x - point.x) }),
              abs(nearest.x - point.x) <= 32 else { return }
        focus = .stop(nearest.id)
    }

    /// The focus for a point on the line: a stop when the point is at its dot, otherwise the
    /// share of the way between the two stops either side.
    static func focus(at x: CGFloat, nodes: [LineNode]) -> JourneyMapFocus? {
        guard let first = nodes.first, let last = nodes.last else { return nil }
        guard nodes.count > 1 else { return .stop(first.id) }
        if x <= first.x { return .between(first.id, nodes[1].id, t: 0) }
        if x >= last.x { return .between(nodes[nodes.count - 2].id, last.id, t: 1) }
        let upper = nodes.firstIndex { $0.x >= x } ?? nodes.count - 1
        let from = nodes[max(upper - 1, 0)], to = nodes[upper]
        if x - from.x <= snapDistance { return .between(from.id, to.id, t: 0) }
        if to.x - x <= snapDistance { return .between(from.id, to.id, t: 1) }
        return .between(from.id, to.id, t: Double((x - from.x) / max(to.x - from.x, 1)))
    }
}

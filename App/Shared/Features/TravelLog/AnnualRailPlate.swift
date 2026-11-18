import Foundation
import TrainTrackerCore

/// Separate map insets keep distant railways legible. A journey is always drawn in one piece.
struct AnnualRailPlate {
    let routes: [AnnualRailRoute]

    var caption: String {
        guard let first = routes.first?.entry else { return "" }
        if routes.count == 1 {
            if let origin = first.originCode, let destination = first.destinationCode,
               !origin.isEmpty, !destination.isEmpty, origin.count <= 6, destination.count <= 6 {
                return "\(origin)  →  \(destination)"
            }
            return first.departureText(.dateTime.month(.abbreviated).day())
        }
        return "\(routes.count.formatted()) rides"
    }

    func projected(in rect: CGRect) -> [[CGPoint]] {
        JourneyHistoryRouteTrace.project(routes.map(\.points), in: rect)
    }

    static func group(_ routes: [AnnualRailRoute]) -> [Self] {
        guard !routes.isEmpty else { return [] }
        var plates = [Self(routes: routes)]
        while plates.count < 3 {
            let candidates = plates.enumerated().compactMap { index, plate in
                plate.division().map { (index, $0) }
            }
            guard let (index, split) = candidates.max(by: { $0.1.gap < $1.1.gap }) else { break }
            plates.replaceSubrange(index...index, with: [Self(routes: split.first), Self(routes: split.second)])
        }
        // Give the largest mapped ride the lead inset, including when several journeys share it.
        return plates.sorted {
            ($0.routes.map { $0.entry.distanceMeters }.max() ?? 0) >
            ($1.routes.map { $0.entry.distanceMeters }.max() ?? 0)
        }
    }

    private struct Division {
        let gap: Double
        let first: [AnnualRailRoute]
        let second: [AnnualRailRoute]
    }

    private func division() -> Division? {
        guard routes.count > 1, let anchor = routes.first?.points.first else { return nil }
        let eastScale = max(0.1, cos(anchor.latitude * .pi / 180))
        let east = largestGap { point in
            var delta = point.longitude - anchor.longitude
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            return delta * eastScale
        }
        let north = largestGap { $0.latitude }
        return [east, north].compactMap { $0 }.max { $0.gap < $1.gap }
    }

    private func largestGap(along axis: (GeoCoordinate) -> Double) -> Division? {
        let spans = routes.map { route in
            let values = route.points.map(axis)
            return (route: route, low: values.min()!, high: values.max()!)
        }.sorted { $0.low < $1.low }
        guard let start = spans.first else { return nil }
        var high = start.high
        var gap = 0.0
        var split = 0
        for index in spans.indices.dropFirst() {
            let distance = spans[index].low - high
            if distance > gap {
                gap = distance
                split = index
            }
            high = max(high, spans[index].high)
        }
        // Roughly 300 km of empty space, and enough space to materially shrink the routes.
        guard gap > 3, gap > (high - start.low) * 0.24 else { return nil }
        return Division(gap: gap, first: spans[..<split].map(\.route), second: spans[split...].map(\.route))
    }
}

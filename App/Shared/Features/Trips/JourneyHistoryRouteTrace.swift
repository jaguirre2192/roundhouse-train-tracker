import Foundation
import TrainTrackerCore

/// A north-up station diagram from the saved itinerary. Each array is one known leg, so
/// a missing transfer between legs never turns into a line on the ticket.
struct JourneyHistoryRouteTrace {
    let legs: [[GeoCoordinate]]
    let originCode: String?
    let destinationCode: String?

    init?(legs: [[GeoCoordinate]], originCode: String?, destinationCode: String?) {
        guard let origin = legs.first?.first, let destination = legs.last?.last,
              origin != destination,
              legs.allSatisfy({ $0.count >= 2 && $0.allSatisfy(Self.valid) }) else { return nil }
        self.legs = legs
        self.originCode = originCode
        self.destinationCode = destinationCode
    }

    static func valid(_ point: GeoCoordinate) -> Bool {
        point.latitude.isFinite && point.longitude.isFinite
            && (-90...90).contains(point.latitude) && (-180...180).contains(point.longitude)
            && (point.latitude != 0 || point.longitude != 0)
    }

    /// Preserve compass direction and a common scale, including routes that cross 180°.
    /// The small printed field needs the station pattern, not map tiles or a network request.
    func projected(in rect: CGRect) -> [[CGPoint]] {
        Self.project(legs, in: rect)
    }

    /// Independent route strokes share a north-up projection and never join across journeys.
    static func project(_ legs: [[GeoCoordinate]], in rect: CGRect) -> [[CGPoint]] {
        guard rect.width > 0, rect.height > 0, let origin = legs.first?.first else { return [] }
        let locations = legs.joined()
        let latitudes = locations.map(\.latitude)
        guard let south = latitudes.min(), let north = latitudes.max() else { return [] }
        let longitudeScale = cos((south + north) * .pi / 360)
        let points = legs.map { leg in
            leg.map { location in
                var longitude = location.longitude - origin.longitude
                if longitude > 180 { longitude -= 360 }
                if longitude < -180 { longitude += 360 }
                return CGPoint(x: longitude * longitudeScale, y: -location.latitude)
            }
        }
        var bounds = CGRect.null
        for point in points.joined() {
            bounds = bounds.union(CGRect(origin: point, size: .zero))
        }
        let scale = min(bounds.width == 0 ? .infinity : rect.width / bounds.width,
                        bounds.height == 0 ? .infinity : rect.height / bounds.height)
        guard scale.isFinite, scale > 0 else { return [] }
        return points.map { leg in
            leg.map { CGPoint(x: rect.midX + ($0.x - bounds.midX) * scale,
                              y: rect.midY + ($0.y - bounds.midY) * scale) }
        }
    }
}

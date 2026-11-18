import Testing
@testable import TrainTrackerCore

@Test func routeGeometryDecodesGooglePolylineAndJoinsSegments() throws {
    let segment = RouteGeometry.Segment(
        encodedPolyline: "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
        precision: 5,
        pointCount: 3
    )
    let geometry = RouteGeometry(source: "Fixture", segments: [segment])

    #expect(geometry.coordinates.count == 3)
    #expect(abs(try #require(geometry.coordinates.first).latitude - 38.5) < 0.000_001)
    #expect(abs(try #require(geometry.coordinates.first).longitude + 120.2) < 0.000_001)
    #expect(abs(try #require(geometry.coordinates.last).latitude - 43.252) < 0.000_001)
    #expect(abs(try #require(geometry.coordinates.last).longitude + 126.453) < 0.000_001)
}

@Test func routeGeometryRejectsMalformedOrMismatchedPolylines() {
    #expect(RouteGeometry.Segment(
        encodedPolyline: "invalid",
        precision: 5,
        pointCount: 3
    ).coordinates.isEmpty)
    #expect(RouteGeometry.Segment(
        encodedPolyline: "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
        precision: 9,
        pointCount: 3
    ).coordinates.isEmpty)
}

import MapKit
import SwiftUI
import TrainTrackerCore

enum TripRouteMapChrome {
    case full
    case compact
}

struct TripRouteMapView: View {
    let trip: TrainTrip
    var chrome: TripRouteMapChrome = .compact
    var trips: [TrainTrip] = []
    var selectTrip: (TrainTrip) -> Void = { _ in }
    var isRefreshing = false
    var refreshTrip: (() -> Void)? = nil
    var refreshDidFail: () -> Bool = { false }
    var userLocation: CLLocation? = nil
    /// Height covered by a details sheet resting over the map, so the route is framed above it.
    var bottomInset: CGFloat = 0
    /// The map runs under the status bar and every bar and panel, as the screen's backdrop.
    var fillsScreen = false
    /// Further height a panel covers beyond `bottomInset`. The map keeps its size and tiles; only
    /// the camera moves, so the route stays in the part of the map still showing.
    var obscuredBottom: CGFloat = 0
    /// Width a panel floating over the map's leading side takes, on a wide screen. The route is
    /// framed in what is left beside it, and the map's own controls start after it.
    var leadingInset: CGFloat = 0
    /// How current the journey's times are. When given, the map shows this one mark instead of
    /// a separate position badge, so the map never claims more than the ticket does.
    var trust: JourneyTrust? = nil
    var freshness: TripFreshness = .notChecked
    /// A stop or a point along the line the rider asked to see. The camera goes to it and a
    /// mark is drawn there; the camera button, or a hand on the map, lets it go.
    var focus: Binding<JourneyMapFocus?> = .constant(nil)
    /// What the mark at a focused stop says: its name and time.
    var focusCaption: String? = nil

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.journeyReferenceDate) private var referenceDate
    @AppStorage(TrainTrackerPreference.mapStyle) private var mapStylePreference = MapStylePreference.muted
    @State private var cameraPosition: MapCameraPosition = .automatic
    /// The route measured along its length, rebuilt only when the route itself changes.
    @State private var path: RoutePath?
    /// The clock the train glides by, ticking once a second while the map is on screen.
    @State private var glideDate = Date.now
    @State private var framing = Framing.route
    @State private var viewportSize: CGSize = .zero
    private var mapHeight: CGFloat { viewportSize.height }
    @State private var safeArea = EdgeInsets()

    /// What the camera holds in view.
    private enum Framing {
        /// The whole journey.
        case route
        /// The train and the stop it is heading for, kept in view as the train moves.
        case ahead
        /// A place the rider picked from the stop list or the ticket's line.
        case focus
    }

    /// The light casing under each route line. Over satellite imagery it is always ivory, so the
    /// line reads in both appearances.
    private var routeCasing: Color {
        mapStylePreference.usesImagery ? .ttTextOnBrand : .ttBackgroundElevated
    }
    @State private var statusDate = Date.now
    /// Height of the journey ticket docked at the bottom on compact width, so the map frames the
    /// route above it and keeps its own marks clear of it.
    @State private var bottomPanelHeight: CGFloat = 0

    var body: some View {
        framedMap
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            let previous = viewportSize
            viewportSize = size
            guard previous != .zero, size.width > 0, size.height > 0,
                  !cameraPosition.positionedByUser else { return }
            // A fold, rotation or sidebar toggle changes the visible map even when its
            // panel inset stays the same. Preserve the chosen focus and refit its region.
            cameraPosition = .region(framed(currentRegion))
        }
        .onChange(of: obscuredBottom) {
            // The panel moved: slide the route into what is left of the map.
            guard !cameraPosition.positionedByUser else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.9)) {
                cameraPosition = .region(framed(currentRegion))
            }
        }
        .onChange(of: leadingInset) {
            // The panel moved beside the map, or back under it: fit the route to the new room.
            guard !cameraPosition.positionedByUser else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.4)) {
                cameraPosition = .region(framed(currentRegion))
            }
        }
        .onChange(of: focus.wrappedValue) { old, new in
            guard let new, let target = focusRegion(new) else {
                // Let go by the panel: step back to the whole route. A hand on the map has
                // already taken the camera, and keeps it.
                if old != nil, framing == .focus { fitRoute() }
                return
            }
            framing = .focus
            // A slide along the line follows the finger; a chosen stop is flown to.
            let sliding: Bool = { if case .between = new { true } else { false } }()
            withAnimation(sliding ? .linear(duration: 0.12) : (reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.7))) {
                cameraPosition = .region(framed(target))
            }
        }
        .task(id: routeKey) {
            path = RoutePath(coordinates: TripRouteMapGeometry.exactRouteCoordinates(in: trip) ?? [])
        }
        .task(id: glidesNow) {
            // One step a second is smooth at the scales a train is watched at and costs little.
            guard glidesNow else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                glideDate = .now
                if framing == .ahead, !cameraPosition.positionedByUser, let ahead = aheadRegion {
                    withAnimation(.linear(duration: 1)) { cameraPosition = .region(framed(ahead)) }
                }
            }
        }
        .onChange(of: cameraPosition.positionedByUser) { _, byUser in
            // A hand on the map takes the camera back.
            if byUser {
                framing = .route
                focus.wrappedValue = nil
            }
        }
        .onChange(of: trip) {
            // A refresh keeps the same trip ID. Evaluate newly received GPS and passage
            // reports against its receipt time, not the previous minute's display clock.
            guard referenceDate == nil else { return }
            let receivedAt = Date.now
            statusDate = receivedAt
            glideDate = receivedAt
        }
        .task(id: trip.id) {
            framing = .route
            cameraPosition = .region(framed(region))
            statusDate = .now
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                statusDate = .now
            }
        }
    }

    /// The map with whatever surrounds it. Filling the screen, the map itself runs past every
    /// edge while a clear frame inside the safe area carries the controls, so they stay clear of
    /// the status bar and the header.
    @ViewBuilder
    private var framedMap: some View {
        if fillsScreen {
            Color.clear
                .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safeArea = $0 }
                .background {
                    map
                        // Room for the trust mark and the camera button under the header.
                        .safeAreaPadding(.top, safeArea.top + TrainTrackerSpacing.space48)
                        .safeAreaPadding(.bottom, safeArea.bottom + bottomInset)
                        .safeAreaPadding(.leading, safeArea.leading + leadingInset)
                        .safeAreaPadding(.trailing, safeArea.trailing)
                        .ignoresSafeArea()
                }
                .overlay(alignment: .topTrailing) { compactControls }
        } else {
            inlineMap
        }
    }

    private var inlineMap: some View {
        map
        // On regular width the summary floats as a side panel; keep the route framed beside it.
        .safeAreaPadding(.leading, usesSidePanel ? LayoutMetrics.sidePanelWidth + LayoutMetrics.pageInset : 0)
        .safeAreaPadding(.bottom, usesBottomPanel ? bottomPanelHeight + TrainTrackerSpacing.space16 : bottomInset)
        // Compact width leads with the map: the journey sits beneath it as a ticket, the way a
        // sheet would, and the train stays in view above.
        .overlay(alignment: usesSidePanel ? .topLeading : (usesBottomPanel ? .bottom : .top)) {
            switch chrome {
            case .full:
                MapTripSummary(
                    trip: trip,
                    position: latestPosition,
                    trips: trips,
                    selectTrip: selectTrip,
                    isRefreshing: isRefreshing,
                    refreshTrip: refreshTrip ?? {},
                    refreshDidFail: refreshDidFail,
                    fitRoute: fitRoute,
                    now: evidenceDate
                )
                .frame(maxWidth: usesSidePanel ? LayoutMetrics.sidePanelWidth : .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomPanelHeight = $0 }
                .padding(.horizontal, LayoutMetrics.pageInset)
                .padding(usesBottomPanel ? .bottom : .top, TrainTrackerSpacing.space8)
                .ignoresSafeArea(.container, edges: usesSidePanel ? .leading : [])
            case .compact:
                compactControls
            }
        }
    }

    /// The map and everything drawn on it.
    private var map: some View {
        Map(position: $cameraPosition) {
            if let userLocation, isCurrentLocation(userLocation) {
                MapCircle(
                    center: userLocation.coordinate,
                    radius: max(userLocation.horizontalAccuracy, 25)
                )
                .foregroundStyle(Color.blue.opacity(0.1))
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)

                Annotation("Your approximate location", coordinate: userLocation.coordinate, anchor: .center) {
                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: 26, height: 26)
                            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 18, height: 18)
                            .overlay {
                                Circle().stroke(.white, lineWidth: 2)
                            }
                    }
                    .accessibilityLabel(
                        "Your approximate location, within \(Int(userLocation.horizontalAccuracy.rounded(.up))) meters"
                    )
                }
                .annotationTitles(.hidden)
            }

            // The same reading as the ticket's route line: travelled is solid teal, the way ahead
            // is quiet ink. A route known only at its stops is dotted ahead, since its exact path
            // is not known.
            let glide = glide
            let glideClock = referenceDate ?? glideDate
            let routes = TripRouteMapGeometry.drawnRoutes(
                in: trip, position: latestPosition, referenceDate: evidenceDate
            )
            if routes.upcoming.count > 1 {
                MapPolyline(coordinates: routes.upcoming)
                    .stroke(routeCasing.opacity(0.9), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: routes.upcoming)
                    .stroke(
                        // Ink by day, ivory by night, so the way ahead reads on a dark map too.
                        Color.ttTextBrand.opacity(0.78),
                        style: routes.isSchematic
                            ? StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round, dash: [0.5, 7.5])
                            : StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
                    )
            }
            if routes.passed.count > 1 {
                MapPolyline(coordinates: routes.passed)
                    .stroke(routeCasing, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: routes.passed)
                    .stroke(Color.ttRouteActive, style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            }

            ForEach(mapStops.filter { $0.id != focus.wrappedValue?.stopID }) { item in
                Annotation(
                    item.accessibilityLabel,
                    coordinate: item.stop.station.mapCoordinate,
                    anchor: item.annotationAnchor
                ) {
                    MapStopMarker(
                        item: item,
                        calloutExtendsLeft: item.stop.station.mapCoordinate.longitude >= currentRegion.center.longitude
                    )
                }
                .annotationTitles(.hidden)
            }

            if let position = latestPosition {
                let isEstimated = glide?.isEstimated(at: glideClock) ?? false
                if isEstimated {
                    // Where the operator last reported the train; the marker has moved on from it.
                    Annotation("Last reported position", coordinate: position.coordinate.mapCoordinate, anchor: .center) {
                        Circle()
                            .fill(Color.ttBackgroundElevated)
                            .overlay { Circle().strokeBorder(Color.ttActionLive, lineWidth: 2.5) }
                            .frame(width: 11, height: 11)
                            .accessibilityHidden(true)
                    }
                    .annotationTitles(.hidden)
                }
                Annotation(
                    trust == .saved ? "Last saved train position"
                        : isEstimated ? "Estimated train position between reports" : positionStatus.annotationLabel,
                    coordinate: glide?.coordinate(at: glideClock) ?? position.coordinate.mapCoordinate,
                    anchor: .center
                ) {
                    VehicleMapMarker(
                        status: positionStatus,
                        nearbyNextStopName: nearbyNextStop?.station.displayName,
                        isSaved: trust == .saved,
                        isBetweenReports: isEstimated
                    )
                }
            }
            if let focus = focus.wrappedValue, let coordinate = focus.coordinate(in: trip, path: path) {
                Annotation(focusCaption ?? "Selected place", coordinate: coordinate, anchor: .center) {
                    MapFocusMarker(caption: focus.stopID == nil ? nil : focusCaption)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(mapStylePreference.mapStyle)
        .accessibilityLabel(
            "Route map from \(trip.origin?.displayName ?? "origin") to \(trip.destination?.displayName ?? trip.headsign)"
        )
    }

    private var compactControls: some View {
        JourneyMapControls(
            trust: trust, freshness: freshness, referenceDate: evidenceDate,
            position: latestPosition, positionStatus: positionStatus,
            isRefreshing: isRefreshing, refresh: refreshTrip,
            framingSymbol: framing == .route ? "location.viewfinder" : "point.topleft.down.to.point.bottomright.curvepath",
            framingLabel: framing != .route || aheadRegion == nil ? "Show whole route" : "Follow train",
            reframe: toggleFraming,
            leadingInset: leadingInset
        )
    }

    private var usesBottomPanel: Bool {
        chrome == .full && !usesSidePanel
    }

    private var usesSidePanel: Bool {
        chrome == .full && horizontalSizeClass == .regular
    }

    private var evidenceDate: Date { referenceDate ?? statusDate }

    private var latestPosition: VehiclePosition? {
        TripRouteMapGeometry.latestPosition(in: trip, referenceDate: evidenceDate)
    }

    private var positionStatus: TrainPositionStatus {
        TrainPositionStatus(position: latestPosition, now: evidenceDate)
    }

    private var nearbyNextStop: StopTime? {
        TripRouteMapGeometry.nearbyNextStop(in: trip, position: latestPosition, referenceDate: evidenceDate)
    }



    private var mapStops: [MapStop] {
        TripRouteMapGeometry.mapStops(in: trip, nearbyNextStop: nearbyNextStop, referenceDate: evidenceDate)
    }

    private var region: MKCoordinateRegion {
        TripRouteMapGeometry.region(for: trip)
    }

    private func isCurrentLocation(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= 1_000
            && Date.now.timeIntervalSince(location.timestamp) >= -5
            && Date.now.timeIntervalSince(location.timestamp) <= 120
    }

    private func fitRoute() {
        framing = .route
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .region(framed(region))
        }
    }

    /// Follow the train toward its next stop, or step back to the whole route.
    private func toggleFraming() {
        if framing == .focus {
            // Clearing the focus steps back to the whole route.
            focus.wrappedValue = nil
            return fitRoute()
        }
        guard framing == .route, let ahead = aheadRegion else { return fitRoute() }
        framing = .ahead
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.9)) {
            cameraPosition = .region(framed(ahead))
        }
    }

    /// What the camera is holding now, before it is fitted above the panel.
    private var currentRegion: MKCoordinateRegion {
        switch framing {
        case .route: region
        case .ahead: aheadRegion ?? region
        case .focus: focus.wrappedValue.flatMap(focusRegion) ?? region
        }
    }

    /// A chosen stop is shown at the scale of its town; a slide along the line keeps a wider
    /// view, in proportion to the route, so the track ahead stays in the picture.
    private func focusRegion(_ focus: JourneyMapFocus) -> MKCoordinateRegion? {
        guard let center = focus.coordinate(in: trip, path: path) else { return nil }
        let span: CLLocationDegrees
        switch focus {
        case .stop:
            span = 0.09
        case .between:
            let route = region.span
            span = min(max(max(route.latitudeDelta, route.longitudeDelta) * 0.22, 0.12), 1.4)
        }
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
    }

    /// A region grown downward so that what it was asked to show sits above a panel covering
    /// `obscuredBottom` of the map.
    private func framed(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        let visible = mapHeight - bottomInset
        guard obscuredBottom > 0, visible > obscuredBottom + 80 else { return region }
        let growth = visible / (visible - obscuredBottom)
        let latitudeDelta = min(region.span.latitudeDelta * growth, 170)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: max(region.center.latitude - (latitudeDelta - region.span.latitudeDelta) / 2, -85),
                longitude: region.center.longitude
            ),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: region.span.longitudeDelta)
        )
    }

    /// The train's estimated place between reports, when its position is real and on the route.
    private var glide: TrainGlide? {
        // A journey not yet checked this session shows its saved position where it was saved.
        guard trust?.isConfirmed ?? true, let path, let position = latestPosition else { return nil }
        return TrainGlide(trip: trip, position: position, path: path, referenceDate: evidenceDate)
    }

    /// Whether the glide clock should run: a train to carry, a visible map, and motion allowed.
    private var glidesNow: Bool {
        glide != nil && referenceDate == nil && scenePhase == .active && !reduceMotion
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Changes only when the route line itself does.
    private var routeKey: String {
        "\(trip.id.rawValue)|\(trip.routeGeometry?.coordinates.count ?? 0)|\(trip.stopTimes.count)"
    }

    /// The train and the stop it is heading for, with the train held back from the center so
    /// the camera leads it.
    private var aheadRegion: MKCoordinateRegion? {
        guard let position = TripRouteMapGeometry.confirmedPosition(in: trip, referenceDate: evidenceDate),
              let next = TripRouteMapGeometry.observedNextStop(in: trip, referenceDate: evidenceDate) else { return nil }
        let train = glide?.coordinate(at: referenceDate ?? glideDate) ?? position.coordinate.mapCoordinate
        let stop = next.station.mapCoordinate
        let latitudeSpan = abs(train.latitude - stop.latitude), longitudeSpan = abs(train.longitude - stop.longitude)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: train.latitude + (stop.latitude - train.latitude) * 0.55,
                longitude: train.longitude + (stop.longitude - train.longitude) * 0.55
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(latitudeSpan * 1.9, 0.07),
                longitudeDelta: max(longitudeSpan * 1.9, 0.07)
            )
        )
    }
}

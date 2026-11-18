import SwiftUI
import TrainTrackerCore

enum MapTripSummaryLayout {
    static let controlTargetSize: CGFloat = 44

    static func stacksStatus(at dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    static func tripTitleLineLimit(at dynamicTypeSize: DynamicTypeSize) -> Int {
        dynamicTypeSize.isAccessibilitySize ? 2 : 1
    }
}

struct MapTripSummary: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let trip: TrainTrip
    let position: VehiclePosition?
    let trips: [TrainTrip]
    let selectTrip: (TrainTrip) -> Void
    let isRefreshing: Bool
    let refreshTrip: () -> Void
    /// Whether the check that just ended failed; drives the refresh symbol's outcome.
    var refreshDidFail: () -> Bool = { false }
    let fitRoute: () -> Void
    var now: Date = .now

    private let secondaryOnInk = Color.ttTextOnBrand.opacity(0.72)

    /// A compact ink Line Ticket floating over the map: train and controls, codes joined by a
    /// short route line, the full route, then where the position came from and how fresh it is.
    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    tripSelector
                    mapControls
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(alignment: .center, spacing: TrainTrackerSpacing.space8) {
                    tripSelector
                        .layoutPriority(1)
                    Spacer(minLength: TrainTrackerSpacing.space8)
                    mapControls
                }
            }

            route

            // How the train is running, in the words the ticket and My Trips use.
            Text(TripPresentationStatus(trip: trip, referenceDate: now).text)
                .font(.headline)
                .foregroundStyle(Color.ttTextOnBrand)
                .contentTransition(.numericText())
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, TrainTrackerSpacing.space2)

            if showsTicketDetail {
                RouteLineSummaryView(summary: routeSummary, palette: .onInk)
                    .padding(.top, TrainTrackerSpacing.space4)
                TicketPerforation.onInk
                    .padding(.horizontal, -LayoutMetrics.cardInset)
                TicketStubGrid(fields: stubFields, labelColor: secondaryOnInk, valueColor: .ttTextOnBrand)
            }

            positionLine

            if AmtrakerAttributionLink.applies(to: trip) {
                AmtrakerAttributionLink()
                    .tint(Color.ttTextOnBrand)
            }
        }
        .padding(.horizontal, LayoutMetrics.cardInset)
        .padding(.vertical, TrainTrackerSpacing.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same printed ink stock as the ticket on My Trips, notched at its perforation.
        .liveTicketStyle()
    }

    /// The ticket's route line and stub show wherever text is at a standard size: in the side
    /// panel on regular width and in the ticket docked beneath the map on a phone.
    private var showsTicketDetail: Bool {
        !dynamicTypeSize.isAccessibilitySize
    }

    /// Live blue on the line only for a live or recent position.
    private var routeSummary: RouteLineSummary {
        let progress = RailJourneyProgress(trip: trip, referenceDate: now)
        let status = TrainPositionStatus(position: position, now: now)
        return RouteLineSummary(
            stops: progress.stops, focusStopID: progress.focusStop?.id, phase: progress.phase,
            referenceDate: now, showsLiveMarker: status == .live || status == .recent,
            confirmedPassedStopIDs: progress.evidence.confirmedPassedStopIDs, isArrivalConfirmed: progress.evidence.isArrivalConfirmed
        )
    }

    private var stubFields: [TicketStubField] {
        let next = trip.nextStop
        let time = next.flatMap { StopTimelineTimePresentation(stop: $0, event: .arrival).timeText }
        return [
            TicketStubField(
                id: "next", label: "Next",
                value: next.map { StationShortCode.code(for: $0.station) ?? $0.station.displayName } ?? TicketStubField.unavailableValue
            ),
            TicketStubField(id: "arrives", label: "Arrives", value: time ?? TicketStubField.unavailableValue, usesNumericDigits: true),
            TicketStubField(
                id: "platform", label: next?.platformNoun ?? "Platform",
                value: next?.displayPlatform ?? TicketStubField.unavailableValue, usesNumericDigits: true
            ),
        ]
    }

    @ViewBuilder
    private var route: some View {
        let originCode = StationShortCode.code(for: trip.origin)
        let destinationCode = StationShortCode.code(for: trip.destination)
        let names = "\(trip.origin?.displayName ?? "Origin") → \(trip.destination?.displayName ?? trip.headsign)"
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
            if let originCode, let destinationCode, !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: TrainTrackerSpacing.space12) {
                    Text(originCode)
                    // The side panel's route line below carries progress; the rail here would
                    // repeat it, so the codes simply name the two ends.
                    if showsTicketDetail {
                        Spacer(minLength: TrainTrackerSpacing.space12)
                    } else {
                        Capsule()
                            .fill(Color.ttRouteOnInk)
                            .frame(height: 2)
                            .accessibilityHidden(true)
                    }
                    Text(destinationCode)
                }
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.ttTextOnBrand)
                .accessibilityHidden(true)
            }
            Text(names)
                .font(.footnote)
                .foregroundStyle(secondaryOnInk)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var positionLine: some View {
        let status = TrainPositionStatus(position: position, now: now)
        return HStack(spacing: TrainTrackerSpacing.space8) {
            Circle()
                .fill(Self.onInkColor(for: status))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Group {
                if let position {
                    Text("\(status.title) · Updated \(position.asOf, style: .relative)")
                } else {
                    Text(status.title)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(secondaryOnInk)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Live blue only for a live or recent position; stale positions read as a warning.
    static func onInkColor(for status: TrainPositionStatus) -> Color {
        switch status {
        case .live, .recent: .ttActionLiveOnInk
        case .stale: .ttStatusDelayedOnInk
        case .estimated: .ttRouteOnInk
        case .unavailable: Color.ttTextOnBrand.opacity(0.72)
        }
    }

    private var mapControls: some View {
        HStack(spacing: 0) {
            refreshButton
            Rectangle()
                .fill(Color.ttTextOnBrand.opacity(0.24))
                .frame(width: 0.75, height: 24)
            fitRouteButton
        }
        .background(
            Color.ttTextOnBrand.opacity(0.1),
            in: RoundedRectangle(cornerRadius: TrainTrackerRadius.control, style: .continuous)
        )
    }

    private var refreshButton: some View {
        Button(action: refreshTrip) {
            RefreshStateLabel(isRefreshing: isRefreshing, didFail: refreshDidFail)
                .font(.system(size: 17, weight: .semibold))
            .frame(
                width: MapTripSummaryLayout.controlTargetSize,
                height: MapTripSummaryLayout.controlTargetSize
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.ttTextOnBrand)
        .tint(Color.ttTextOnBrand)
        .disabled(isRefreshing)
        .accessibilityLabel(isRefreshing ? "Refreshing train position" : "Refresh train position")
        .accessibilityHint("Requests the latest available position for the selected trip")
    }

    private var fitRouteButton: some View {
        Button(action: fitRoute) {
            Image(systemName: "viewfinder")
                .font(.system(size: 17, weight: .semibold))
                .frame(
                    width: MapTripSummaryLayout.controlTargetSize,
                    height: MapTripSummaryLayout.controlTargetSize
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.ttTextOnBrand)
        .accessibilityLabel("Fit route on map")
        .accessibilityHint("Centers the selected trip and shows its full route")
    }

    @ViewBuilder
    private var tripSelector: some View {
        if trips.count > 1 {
            Menu {
                ForEach(trips) { option in
                    Button {
                        selectTrip(option)
                    } label: {
                        if option.id == trip.id {
                            Label(option.product, systemImage: "checkmark")
                        } else {
                            Text(option.product)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(trip.product)
                        .lineLimit(MapTripSummaryLayout.tripTitleLineLimit(at: dynamicTypeSize))
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .font(.headline)
                .foregroundStyle(Color.ttTextOnBrand)
            }
            .accessibilityLabel("Mapped trip, \(trip.product)")
            .accessibilityHint("Choose another tracked trip")
        } else {
            Text(trip.product)
                .font(.headline)
                .foregroundStyle(Color.ttTextOnBrand)
                .lineLimit(MapTripSummaryLayout.tripTitleLineLimit(at: dynamicTypeSize))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PositionStatusBadge: View {
    enum Style {
        case standard
        case compact
    }

    let position: VehiclePosition?
    var now: Date = .now
    var style: Style = .standard

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, style == .compact ? TrainTrackerSpacing.space8 : TrainTrackerSpacing.space12)
            .padding(.vertical, style == .compact ? TrainTrackerSpacing.space4 : TrainTrackerSpacing.space6)
            .foregroundStyle(statusColor)
            .background(Color.ttBackgroundBrandSubtle, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(statusColor.opacity(0.24), lineWidth: TrainTrackerStroke.subtle)
            }
    }

    private var title: String {
        status.title
    }

    private var symbol: String {
        switch status {
        case .live: "dot.radiowaves.left.and.right"
        case .recent: "clock.badge.checkmark"
        case .stale: "clock.badge.exclamationmark"
        case .estimated: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .unavailable: "location.slash"
        }
    }

    private var statusColor: Color {
        switch status {
        case .live, .recent: .ttActionLive
        case .stale: .ttStatusDelayed
        case .estimated: .ttRouteActive
        case .unavailable: .ttTextSecondary
        }
    }

    private var status: TrainPositionStatus {
        TrainPositionStatus(position: position, now: now)
    }
}

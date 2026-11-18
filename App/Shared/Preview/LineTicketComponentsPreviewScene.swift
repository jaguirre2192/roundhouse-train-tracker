#if DEBUG
import SwiftUI
import TrainTrackerCore

/// QA gallery for the Line Ticket building blocks. Launch with `-LineTicketComponentsPreview`.
struct LineTicketComponentsPreviewScene: View {
    private let referenceDate = Date(timeIntervalSince1970: 1_784_574_000)

    private var trip: TrainTrip? {
        PreviewTrips.make(referenceDate: referenceDate).first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                    if let trip {
                        sample(title: "Live ticket · ink", trip: trip, live: true, coach: "6", seat: "14A", onInk: true)
                        sample(title: "Stub · white hairline", trip: trip, live: false, coach: nil, seat: nil, onInk: false)
                    }
                    codeFallbacks
                }
                .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
                .padding(LayoutMetrics.pageInset)
                .frame(maxWidth: .infinity)
            }
            .background(Color.ttBackgroundCanvas)
            .navigationTitle("Line Ticket Parts")
        }
    }

    private func sample(
        title: String, trip: TrainTrip, live: Bool, coach: String?, seat: String?, onInk: Bool
    ) -> some View {
        let focus = trip.nextStop
        let summary = RouteLineSummary(
            stops: trip.stopTimes,
            focusStopID: focus?.id,
            phase: .underway,
            referenceDate: referenceDate,
            showsLiveMarker: live
        )
        let fields = TicketStubFields.live(
            nextStop: StationShortCode.code(for: focus?.station) ?? focus?.station.displayName,
            platformNoun: focus?.platformNoun ?? "Platform",
            platform: focus?.displayPlatform,
            coach: coach,
            seat: seat,
            arrivalTime: trip.stopTimes.last.flatMap { StopTimelineTimePresentation(stop: $0, event: .arrival).timeText },
            stopsLeft: trip.stopTimes.filter { !$0.isPassed }.count
        )

        return VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.ttTextSecondary)

            VStack(spacing: 0) {
                VStack(spacing: TrainTrackerSpacing.space16) {
                    HStack(alignment: .firstTextBaseline) {
                        StationCodeText(station: trip.origin, fallbackName: "Origin", foreground: codeColor(onInk))
                        StationCodeText(
                            station: trip.destination, fallbackName: trip.headsign,
                            alignment: .trailing, foreground: codeColor(onInk)
                        )
                    }
                    RouteLineSummaryView(summary: summary, palette: onInk ? .onInk : .standard)
                }
                .padding(LayoutMetrics.cardInset)

                onInk ? TicketPerforation.onInk : TicketPerforation()

                TicketStubGrid(
                    fields: fields,
                    labelColor: onInk ? Color.ttTextOnBrand.opacity(0.72) : .ttTextSecondary,
                    valueColor: onInk ? .ttTextOnBrand : .ttTextPrimary
                )
                .padding(LayoutMetrics.cardInset)
            }
            .modifier(TicketPaper(onInk: onInk))
        }
    }

    private func codeColor(_ onInk: Bool) -> Color {
        onInk ? .ttTextOnBrand : .ttTextBrand
    }

    private struct TicketPaper: ViewModifier {
        let onInk: Bool

        func body(content: Content) -> some View {
            if onInk {
                content.liveTicketStyle()
            } else {
                content.ticketStubStyle()
            }
        }
    }

    private var codeFallbacks: some View {
        let named = Station(
            id: RailIdentifier(rawValue: "de:db:8000105"),
            names: [LocalizedStationName("Frankfurt (Main) Hauptbahnhof")],
            codes: [.eva: "8000105", .sourceNative: "8000105"],
            location: GeoCoordinate(latitude: 50.107, longitude: 8.663),
            countryCode: "DE"
        )
        let coded = Station(
            id: RailIdentifier(rawValue: "gb:nr:PAD"),
            names: [LocalizedStationName("London Paddington")],
            codes: [.crs: "pad"],
            location: GeoCoordinate(latitude: 51.516, longitude: -0.176),
            countryCode: "GB"
        )
        return VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            Text("Code fallback")
                .font(.headline)
                .foregroundStyle(Color.ttTextSecondary)
            HStack(alignment: .top, spacing: TrainTrackerSpacing.space16) {
                StationCodeText(station: coded, fallbackName: "London")
                StationCodeText(station: named, fallbackName: "Frankfurt", alignment: .trailing)
            }
            .padding(LayoutMetrics.cardInset)
            .ticketStubStyle()
        }
    }
}
#endif

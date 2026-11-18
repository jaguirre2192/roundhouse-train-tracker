import MapKit
import SwiftUI
import TrainTrackerCore

/// Everywhere the rider has been. The map of every line ridden runs to the top of the screen; the
/// totals are printed on an ink ticket that rests on its lower edge; each finished journey is a
/// stub torn from its ticket, filed by year.
struct TravelLogView: View {
    @Environment(JourneyPlanLibrary.self) private var planLibrary
    @State private var log = TravelLog.shared
    @Environment(TripLibrary.self) private var tripLibrary
    @AppStorage(TrainTrackerPreference.mapStyle) private var mapStylePreference = MapStylePreference.muted
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entryPendingRemoval: TravelLogEntry?
    @State private var removalError: String?
    @State private var shareItem: TravelLogShareItem?
    @State private var printYear: Int?
    /// False until the screen has appeared, so the totals count up and the stubs arrive in turn.
    @State private var revealed = false
    /// The status bar and navigation bar the map runs under, so the lines are framed below them.
    @State private var topInset: CGFloat = 0

    private static let mapHeight: CGFloat = 390
    /// How far the summary ticket rides up over the map.
    private static let overlap: CGFloat = 96

    var body: some View {
        ScrollView {
            if log.entries.isEmpty {
                emptyState
                    .padding(LayoutMetrics.pageInset)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    map
                    VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                        TravelLogSummaryTicket(totals: log.totals, entries: log.entries, revealed: revealed)
                        stubs
                    }
                    .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, LayoutMetrics.pageInset)
                    .padding(.bottom, TrainTrackerSpacing.space32)
                    .frame(maxWidth: .infinity)
                    .padding(.top, -Self.overlap)
                }
            }
            WindowSeatLink()
                .frame(maxWidth: LayoutMetrics.contentMaxWidth)
                .padding(LayoutMetrics.pageInset)
        }
        .ignoresSafeArea(.container, edges: log.entries.isEmpty ? [] : .top)
        .background {
            Color.clear.onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
        }
        .trainTrackerPageBackground()
        .navigationTitle("Travel Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.9).delay(0.15)) { revealed = true }
        }
        .sheet(item: $shareItem) { TravelLogShareSheet(item: $0) }
        .navigationDestination(item: $printYear) { year in
            if let edition = AnnualRailPrint(year: year, entries: log.entries, plans: planLibrary.plans,
                                            watching: tripLibrary.watchingOnlyIDs) {
                AnnualRailPrintView(edition: edition)
            } else {
                ContentUnavailableView("No Rides This Year", systemImage: "ticket")
            }
        }
        .confirmationDialog(
            "Remove this journey from your Travel Log?",
            isPresented: Binding(get: { entryPendingRemoval != nil }, set: { if !$0 { entryPendingRemoval = nil } }),
            titleVisibility: .visible, presenting: entryPendingRemoval
        ) { entry in
            if tripLibrary.containsTrip(id: RailIdentifier(rawValue: entry.id)) {
                Button("I only watched this train") {
                    do { try log.correctWatchedTrain(entry, in: tripLibrary) }
                    catch { removalError = error.localizedDescription }
                }
            }
            Button("Remove", role: .destructive) {
                do { try log.removePersisting(id: entry.id) }
                catch { removalError = error.localizedDescription }
            }
        } message: { _ in
            Text("Its distance and time will be removed from your totals and railway print.")
        }
        .alert("Couldn’t update your Travel Log", isPresented: Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })) {
            Button("OK") { removalError = nil }
        } message: { Text(removalError ?? "") }
    }

    /// Every line ridden, glowing on the map, which dissolves into the page beneath it.
    private var map: some View {
        Map(initialPosition: .region(region), interactionModes: [.pan, .zoom]) {
            ForEach(log.entries) { entry in
                let line = entry.path.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                MapPolyline(coordinates: line)
                    .stroke(Color.ttRouteActive.opacity(0.28), style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: line)
                    .stroke(mapStylePreference.usesImagery ? Color.ttTextOnBrand : Color.ttBackgroundElevated,
                            style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: line)
                    .stroke(Color.ttBackgroundBrand, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                if let first = line.first, let last = line.last {
                    Annotation(entry.originName, coordinate: first, anchor: .center) { endpoint }
                        .annotationTitles(.hidden)
                    Annotation(entry.destinationName, coordinate: last, anchor: .center) { endpoint }
                        .annotationTitles(.hidden)
                }
            }
        }
        .mapStyle(mapStylePreference.mapStyle)
        .safeAreaPadding(.top, topInset)
        .safeAreaPadding(.bottom, Self.overlap + TrainTrackerSpacing.space16)
        .frame(height: Self.mapHeight)
        .id(topInset)
        .mask {
            LinearGradient(
                stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.62), .init(color: .clear, location: 1)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .accessibilityLabel("Map of every line you have ridden")
    }

    private var endpoint: some View {
        Circle()
            .fill(Color.ttBackgroundElevated)
            .overlay { Circle().strokeBorder(Color.ttBackgroundBrand, lineWidth: 2.5) }
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }

    private var stubs: some View {
        let years = Dictionary(grouping: log.entries, by: \.logYear)
        return VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
            ForEach(years.keys.sorted(by: >), id: \.self) { year in
                VStack(alignment: .leading, spacing: LayoutMetrics.rowSpacing) {
                    HStack(spacing: LayoutMetrics.rowSpacing) {
                        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                            Text(String(year))
                                .font(.title2.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(Color.ttTextPrimary)
                                .accessibilityAddTraits(.isHeader)
                            Text(yearSummary(years[year] ?? []))
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(Color.ttTextSecondary)
                        }
                        Spacer()
                        Button { printYear = year } label: {
                            Label("Railway Print", systemImage: "photo.artframe")
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("View railway print for \(String(year))")
                        .accessibilityIdentifier("annualPrint-\(year)")
                    }
                    ForEach(Array((years[year] ?? []).enumerated()), id: \.element.id) { index, entry in
                        TravelLogStub(entry: entry)
                            .opacity(revealed ? 1 : 0)
                            .offset(y: revealed || reduceMotion ? 0 : 18)
                            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.82).delay(0.25 + Double(index) * 0.07), value: revealed)
                            .contextMenu {
                                Button("Share Stub", systemImage: "square.and.arrow.up") {
                                    shareItem = TravelLogShareItem(entry: entry)
                                }
                                Button("Remove from Travel Log", systemImage: "trash", role: .destructive) {
                                    entryPendingRemoval = entry
                                }
                            }
                    }
                }
            }
        }
    }

    private func yearSummary(_ entries: [TravelLogEntry]) -> String {
        let distance = TravelLogFormat.distance(entries.reduce(0) { $0 + $1.distanceMeters })
        return "\(entries.count == 1 ? "1 ride" : "\(entries.count) rides") · \(distance)"
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No rides yet", systemImage: "ticket")
        } description: {
            Text("Your finished rides appear here as ticket stubs. Together they make your annual railway print.")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, TrainTrackerSpacing.space48)
    }

    /// Every line ridden, with room around it.
    private var region: MKCoordinateRegion {
        let points = log.entries.flatMap(\.path)
        guard let first = points.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
                span: MKCoordinateSpan(latitudeDelta: 35, longitudeDelta: 55)
            )
        }
        let latitudes = points.map(\.latitude), longitudes = points.map(\.longitude)
        let south = latitudes.min() ?? first.latitude, north = latitudes.max() ?? first.latitude
        let west = longitudes.min() ?? first.longitude, east = longitudes.max() ?? first.longitude
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (south + north) / 2, longitude: (west + east) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((north - south) * 1.4, 0.4), longitudeDelta: max((east - west) * 1.4, 0.4))
        )
    }
}

/// The totals, printed on ink ticket stock: the distance as the headline figure, the rest on the
/// stub beneath the perforation.
private struct TravelLogSummaryTicket: View {
    let totals: TravelLog.Totals
    let entries: [TravelLogEntry]
    let revealed: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let secondaryOnInk = Color.ttTextOnBrand.opacity(0.72)

    var body: some View {
        let distance = TravelLogFormat.distance(revealed ? totals.distanceMeters : 0)
            // Some regions set the unit off with a narrow no-break space.
            .split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space12) {
                    Text("Travel Log")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(1.4)
                        .foregroundStyle(secondaryOnInk)
                    Spacer(minLength: 0)
                    if let since {
                        Text(since)
                            .font(.caption2.weight(.semibold).monospaced())
                            .tracking(0.8)
                            .foregroundStyle(Color.ttTextOnBrand.opacity(0.86))
                            .padding(.horizontal, TrainTrackerSpacing.space6)
                            .padding(.vertical, 3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Color.ttTextOnBrand.opacity(0.42), lineWidth: 1)
                            }
                    }
                }
                HStack(alignment: .lastTextBaseline, spacing: TrainTrackerSpacing.space8) {
                    Text(distance.first ?? "0")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.ttTextOnBrand)
                        .contentTransition(.numericText(value: totals.distanceMeters))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Self.unitLabel(distance.count > 1 ? distance[1] : ""))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.ttTextOnBrand)
                        Text("on rails")
                            .font(.subheadline)
                            .foregroundStyle(secondaryOnInk)
                    }
                    if !dynamicTypeSize.isAccessibilitySize {
                        Spacer(minLength: 0)
                        TicketCodeBars(seed: "travel-log-\(totals.journeys)")
                    }
                }
            }
            .padding(LayoutMetrics.cardInset)

            TicketPerforation.onInk

            TicketStubGrid(fields: fields, labelColor: secondaryOnInk, valueColor: .ttTextOnBrand)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LayoutMetrics.cardInset)
        }
        .liveTicketStyle()
        .accessibilityElement(children: .combine)
    }

    private var fields: [TicketStubField] {
        let hours = TravelLogFormat.hours(totals.duration)
        let longest = entries.map(\.distanceMeters).max() ?? 0
        return [
            TicketStubField(id: "journeys", label: totals.journeys == 1 ? "Ride" : "Rides", value: "\(totals.journeys)", usesNumericDigits: true),
            TicketStubField(id: "time", label: hours.unit, value: hours.value, usesNumericDigits: true),
            TicketStubField(id: "stations", label: totals.stations == 1 ? "Station" : "Stations", value: "\(totals.stations)", usesNumericDigits: true),
            TicketStubField(id: "longest", label: "Longest", value: TravelLogFormat.distance(longest), usesNumericDigits: true),
        ]
    }

    /// "SINCE OCT 2026", from the earliest stub.
    private var since: String? {
        entries.map(\.departure).min().map {
            "Since \($0.formatted(.dateTime.month(.abbreviated).year()))".uppercased()
        }
    }

    private static func unitLabel(_ unit: String) -> String {
        switch unit.lowercased() {
        case "mi": "miles"
        case "km": "kilometers"
        case "ft": "feet"
        case "m": "meters"
        default: unit
        }
    }
}

/// One finished journey as the stub torn from its ticket: the day it was ridden on the counterfoil,
/// the route and what the ride came to on the stub, struck with its arrival stamp.
struct TravelLogStub: View {
    let entry: TravelLogEntry
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let secondaryOnInk = Color.ttTextOnBrand.opacity(0.72)

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if !dynamicTypeSize.isAccessibilitySize {
                counterfoil
                tearLine
            }
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space6) {
                // The train's name has the stub's full width; the stamp sits beside the route.
                Text(entry.product)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(secondaryOnInk)
                    .lineLimit(1)
                HStack(alignment: .center, spacing: TrainTrackerSpacing.space8) {
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space6) {
                        HStack(spacing: TrainTrackerSpacing.space8) {
                            Text(entry.originLabel)
                            Image(systemName: "arrow.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.ttRouteOnInk)
                                .accessibilityLabel("to")
                            Text(entry.destinationLabel)
                        }
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.ttTextOnBrand)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .minimumScaleFactor(0.7)
                        Text(distanceAndTime)
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(secondaryOnInk)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
                        if dynamicTypeSize.isAccessibilitySize {
                            Text(entry.departureText(.dateTime.day().month(.abbreviated).year()))
                                .font(.footnote)
                                .foregroundStyle(secondaryOnInk)
                        }
                    }
                    Spacer(minLength: TrainTrackerSpacing.space8)
                    if !dynamicTypeSize.isAccessibilitySize {
                        if entry.isArrivalConfirmed {
                            ArrivalStamp(place: entry.destinationLabel, date: entry.arrival, compact: true)
                        } else {
                            // Kept when the timetable ran out; nothing reported the arrival.
                            TimetableEndMark()
                        }
                    }
                }
            }
            .padding(.leading, TrainTrackerSpacing.space16)
        }
        .padding(.vertical, LayoutMetrics.cardInset)
        .padding(.horizontal, LayoutMetrics.cardInset)
        .padding(.bottom, TrainTrackerSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liveTicketStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.product), \(entry.originName) to \(entry.destinationName), \(entry.departureText(.dateTime.month(.abbreviated).day().year())), \(distanceAndTime), \(running)")
    }

    /// The day of travel, set like a date on a counterfoil.
    private var counterfoil: some View {
        VStack(spacing: 0) {
            Text(entry.departureText(.dateTime.month(.abbreviated)).uppercased())
                .font(.caption2.weight(.bold).monospaced())
                .tracking(1)
                .foregroundStyle(Color.ttRouteOnInk)
            Text(entry.departureText(.dateTime.day()))
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.ttTextOnBrand)
        }
        .frame(width: 46)
        .padding(.trailing, TrainTrackerSpacing.space12)
    }

    private var tearLine: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 1)
            .overlay {
                GeometryReader { proxy in
                    Path { path in
                        path.move(to: CGPoint(x: 0.5, y: 0))
                        path.addLine(to: CGPoint(x: 0.5, y: proxy.size.height))
                    }
                    .stroke(Color.ttTextOnBrand.opacity(0.34), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
            }
            .padding(.vertical, -TrainTrackerSpacing.space6)
            .accessibilityHidden(true)
    }

    /// The stub's times are the last known, not observed, so it says the train arrived (when
    /// that was reported) and nothing about how it ran.
    private var running: String {
        entry.isArrivalConfirmed ? "arrived" : "kept by the timetable, arrival not reported"
    }

    private var distanceAndTime: String {
        "\(TravelLogFormat.distance(entry.distanceMeters)) · \(TravelLogFormat.duration(entry.duration))"
    }
}

/// Where the arrival stamp would be on a stub whose arrival nothing reported: the trust word
/// for what the stub rests on, set quietly, with no claim about how the train ran.
struct TimetableEndMark: View {
    var color: Color = Color.ttTextOnBrand.opacity(0.72)

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Image(systemName: JourneyTrust.timetable.systemImage)
                .font(.caption.weight(.semibold))
            Text("By timetable")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kept by the timetable; the arrival was not reported")
    }
}

/// A row that opens the Travel Log, saying what is in it.
struct TravelLogLink: View {
    @State private var log = TravelLog.shared

    var body: some View {
        TripsRouteLink(route: .travelLog, marksSelection: false) {
            HStack(alignment: .center, spacing: TrainTrackerSpacing.space12) {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                    Text("Travel Log")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(1.4)
                        .foregroundStyle(Color.ttTextOnBrand.opacity(0.72))
                    Text(headline)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ttTextOnBrand)
                    Text(summary)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(Color.ttTextOnBrand.opacity(0.72))
                }
                Spacer(minLength: TrainTrackerSpacing.space8)
                TicketCodeBars(seed: "travel-log-link")
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.ttTextOnBrand.opacity(0.72))
                    .accessibilityHidden(true)
            }
            .padding(LayoutMetrics.cardInset)
            .padding(.bottom, TrainTrackerSpacing.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liveTicketStyle()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("travelLogLink")
    }

    private var headline: String {
        let totals = log.totals
        return totals.journeys > 0 ? "\(TravelLogFormat.distance(totals.distanceMeters)) on rails" : "Your stubs start here"
    }

    private var summary: String {
        let totals = log.totals
        guard totals.journeys > 0 else { return "Each finished ride leaves a ticket stub" }
        let journeys = totals.journeys == 1 ? "1 ride" : "\(totals.journeys) rides"
        return "\(journeys) · \(TravelLogFormat.duration(totals.duration)) · \(totals.stations) stations"
    }
}

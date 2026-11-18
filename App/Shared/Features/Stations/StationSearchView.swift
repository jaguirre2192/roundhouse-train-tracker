import MapKit
import Synchronization
import SwiftUI
import TrainTrackerCore

struct StationSearchView: View {
    @Environment(TripLibrary.self) private var library
    let onTripAdded: (() -> Void)?
    let initialQuery: String?

    @State private var query = ""
    @State private var stations: [RailStationMatch] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var didSearch = false
    @State private var selectedStation: RailStationMatch?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchRequests = LatestRequestGate()

    private let exampleSearches = ["New York Penn", "London Waterloo", "Tokyo Station"]

    init(
        onTripAdded: (() -> Void)? = nil,
        initialSelection: RailStationMatch? = nil,
        initialQuery: String? = nil
    ) {
        self.onTripAdded = onTripAdded
        self.initialQuery = initialQuery
        _query = State(initialValue: initialQuery ?? "")
        _selectedStation = State(initialValue: initialSelection)
    }

    #if DEBUG
    static let berlinPreviewMatch = RailStationMatch(
        station: Station(
            id: RailIdentifier(
                rawValue: "eu:transitous:at-Railway-Current-Reference-Data-2026_de:11000:900003200:1:51"
            ),
            names: [LocalizedStationName("Berlin Hauptbahnhof")],
            codes: [
                .sourceNative: "at-Railway-Current-Reference-Data-2026_de:11000:900003200:1:51"
            ],
            location: GeoCoordinate(latitude: 52.52498, longitude: 13.369114),
            countryCode: "DE",
            operatorHints: []
        ),
        source: .europe
    )
    #endif

    var body: some View {
        List {
            if isSearching {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Searching stations…")
                    }
                    .foregroundStyle(Color.ttTextSecondary)
                }
                .trainTrackerRowSurface()
            } else if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(Color.ttStatusDelayed)

                    Button("Try Again", action: submitSearch)
                }
                .trainTrackerRowSurface()
            } else if !stations.isEmpty {
                Section("Stations") {
                    ForEach(stations) { match in
                        Button {
                            selectedStation = match
                        } label: {
                            HStack(spacing: 12) {
                                StationSearchRow(station: match.station)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.forward")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .trainTrackerRowSurface()
            } else if didSearch, !isSearching, errorMessage == nil {
                Section {
                    ContentUnavailableView.search(text: query)
                }
                .trainTrackerRowSurface()
            } else {
                Section {
                    ContentUnavailableView {
                        Label("Find your station", systemImage: "magnifyingglass")
                    } description: {
                        Text("Search by station name or rail code anywhere in the world.")
                    }
                }
                .trainTrackerRowSurface()

                Section("Try a search") {
                    ForEach(exampleSearches, id: \.self) { example in
                        Button {
                            beginSearch(example)
                        } label: {
                            Label(example, systemImage: "arrow.up.left")
                        }
                    }
                }
                .trainTrackerRowSurface()
            }
        }
        .trainTrackerListCanvas()
        .searchable(text: $query, prompt: "Station name or rail code")
        .onSubmit(of: .search, submitSearch)
        .onChange(of: query) { _, value in
            if StationSearchResultPolicy.shouldClearResults(
                query: value,
                didSearch: didSearch,
                isPresentingBoard: selectedStation != nil
            ) {
                stations = []
                errorMessage = nil
                didSearch = false
            }
        }
        .navigationDestination(item: $selectedStation) { match in
            StationDepartureBoardView(match: match, onTripAdded: onTripAdded)
        }
        .task(id: initialQuery) {
            guard !didSearch, let initialQuery else { return }
            beginSearch(initialQuery)
        }
    }

    private func submitSearch() {
        beginSearch(query)
    }

    /// A new search replaces one in flight: the old request is cancelled and, should its
    /// response still arrive, only the latest request may publish results or errors.
    private func beginSearch(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return }
        searchTask?.cancel()
        let requestID = searchRequests.begin()
        query = value
        isSearching = true
        didSearch = true
        errorMessage = nil

        searchTask = Task {
            let result: Result<[RailStationMatch], Error>
            do {
                result = .success(try await library.searchStations(query: value))
            } catch {
                result = .failure(error)
            }
            guard searchRequests.isLatest(requestID), !Task.isCancelled else { return }
            switch result {
            case let .success(matches):
                stations = matches
            case .failure:
                stations = []
                errorMessage = RailStationSearchError.unavailable.localizedDescription
            }
            isSearching = false
            searchTask = nil
        }
    }
}

/// Numbers overlapping requests so only the most recent one may publish its response.
struct LatestRequestGate: Equatable {
    private(set) var latest = 0

    mutating func begin() -> Int {
        latest += 1
        return latest
    }

    func isLatest(_ requestID: Int) -> Bool {
        requestID == latest
    }
}

enum StationSearchResultPolicy {
    static func shouldClearResults(
        query: String,
        didSearch: Bool,
        isPresentingBoard: Bool
    ) -> Bool {
        query.isEmpty && didSearch && !isPresentingBoard
    }
}

private struct StationDepartureBoardView: View {
    @Environment(TripLibrary.self) private var library

    let match: RailStationMatch
    let onTripAdded: (() -> Void)?

    @State private var departures: [StopTimeSummary] = []
    @State private var isLoading = true
    @State private var addingTripID: RailIdentifier?
    @State private var newlyTrackedTripID: RailIdentifier?
    @State private var errorMessage: String?
    @State private var failedAdd: StopTimeSummary?
    @State private var departureTime = Date.now
    @State private var stationTimeZone: TimeZone?

    init(match: RailStationMatch, onTripAdded: (() -> Void)?) {
        self.match = match
        self.onTripAdded = onTripAdded
        _stationTimeZone = State(initialValue: StationTimeZoneResolver.cached(for: match.station.id))
    }

    /// Board times, the picker and its "today" follow the station's clock, not the device's.
    private var timePresentation: StationBoardTimePresentation {
        StationBoardTimePresentation(timeZone: stationTimeZone ?? .autoupdatingCurrent)
    }

    var body: some View {
        List {
            Section {
                DatePicker(
                    "Departures from",
                    selection: $departureTime,
                    in: timePresentation.selectableRange(from: .now),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .environment(\.timeZone, timePresentation.timeZone)

                Button {
                    departureTime = .now
                } label: {
                    Label("Use Current Time", systemImage: "clock.arrow.circlepath")
                }
            } header: {
                Text("When")
            } footer: {
                if let zone = timePresentation.zoneAbbreviation(at: departureTime) {
                    Text("Times are local to \(match.station.displayName) (\(zone)).")
                }
            }
            .trainTrackerRowSurface()

            Section("Departures") {
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading live departures…")
                            .foregroundStyle(Color.ttTextSecondary)
                    }
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(Color.ttStatusDelayed)
                    Button("Try Again") {
                        Task { await loadBoard(at: departureTime) }
                    }
                } else if departures.isEmpty {
                    ContentUnavailableView(
                        "No departures found",
                        systemImage: "clock",
                        description: Text("Try another date or time.")
                    )
                } else {
                    ForEach(departures) { departure in
                        DepartureSearchRow(
                            departure: departure,
                            timePresentation: timePresentation,
                            isAdding: addingTripID == departure.tripID,
                            isTracked: isTracked(departure),
                            addAction: { add(departure) }
                        )
                    }
                }
            }
            .trainTrackerRowSurface()
        }
        .trainTrackerListCanvas()
        // The board shares the 20 pt page edge and 760 pt reading column with My Trips and detail.
        .trainTrackerReadableWidth(LayoutMetrics.contentMaxWidth, minimumMargin: LayoutMetrics.pageInset)
        .navigationTitle(match.station.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadBoard(at: departureTime)
        }
        .task(id: departureTime) {
            await loadBoard(at: departureTime)
        }
        .task {
            guard stationTimeZone == nil else { return }
            stationTimeZone = await StationTimeZoneResolver.resolve(match.station)
        }
        // A failed Track is the outcome of the person's action: it never replaces the board,
        // and Try Again retries that train rather than reloading departures.
        .alert(
            "Couldn’t Track Train",
            isPresented: Binding(
                get: { failedAdd != nil },
                set: { if !$0 { failedAdd = nil } }
            ),
            presenting: failedAdd
        ) { departure in
            Button("Try Again") { add(departure) }
            Button("Cancel", role: .cancel) {}
        } message: { departure in
            Text("\(departure.product) to \(departure.headsign) wasn’t added. Check your connection and try again.")
        }
    }

    private func loadBoard(at requestedDate: Date) async {
        isLoading = true
        departures = []
        errorMessage = nil

        do {
            let loadedDepartures = try await library.board(
                stationID: match.station.id,
                source: match.source,
                at: requestedDate
            )
            guard !Task.isCancelled, departureTime == requestedDate else { return }
            departures = loadedDepartures
        } catch is CancellationError {
            return
        } catch {
            guard departureTime == requestedDate else { return }
            errorMessage = "We couldn't load departures. Check your connection and try again."
        }
        if departureTime == requestedDate {
            isLoading = false
        }
    }

    private func add(_ departure: StopTimeSummary) {
        guard addingTripID == nil else { return }
        addingTripID = departure.tripID
        failedAdd = nil

        Task {
            do {
                try await library.addTrip(departure, source: match.source)
                newlyTrackedTripID = departure.tripID
                if let origin = library.trip(id: departure.tripID)?.origin {
                    // Lets the saved train's card show its origin's clock.
                    _ = await StationTimeZoneResolver.resolve(origin)
                }
                onTripAdded?()
            } catch {
                failedAdd = departure
            }
            addingTripID = nil
        }
    }

    private func isTracked(_ departure: StopTimeSummary) -> Bool {
        newlyTrackedTripID == departure.tripID || library.trip(id: departure.tripID) != nil
    }
}

/// Formats a station board in the station's own time zone.
struct StationBoardTimePresentation {
    let timeZone: TimeZone
    var deviceTimeZone: TimeZone = .autoupdatingCurrent
    var locale: Locale = .trainTrackerTime

    private var calendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        return calendar
    }

    /// From the start of the station's current day to a year ahead.
    func selectableRange(from now: Date) -> ClosedRange<Date> {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .year, value: 1, to: start)
            ?? start.addingTimeInterval(366 * 24 * 60 * 60)
        return start ... end
    }

    func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
    }

    /// The station's zone abbreviation, only when its clock differs from the device's.
    func zoneAbbreviation(at date: Date) -> String? {
        guard timeZone.secondsFromGMT(for: date) != deviceTimeZone.secondsFromGMT(for: date) else { return nil }
        return timeZone.abbreviation(for: date) ?? timeZone.identifier
    }
}

/// Resolves a station's time zone from its coordinates and remembers it for the session.
enum StationTimeZoneResolver {
    private static let cache = Mutex<[RailIdentifier: TimeZone]>([:])

    static func cached(for stationID: RailIdentifier?) -> TimeZone? {
        guard let stationID else { return nil }
        return cache.withLock { $0[stationID] }
    }

    static func resolve(_ station: Station) async -> TimeZone? {
        if let zone = cached(for: station.id) { return zone }
        guard station.location.latitude != 0 || station.location.longitude != 0 else { return nil }
        let location = CLLocation(latitude: station.location.latitude, longitude: station.location.longitude)
        guard let zone = await reverseGeocodedTimeZone(at: location) else { return nil }
        cache.withLock { $0[station.id] = zone }
        return zone
    }

    private static func reverseGeocodedTimeZone(at location: CLLocation) async -> TimeZone? {
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            return try? await request.mapItems.first?.timeZone
        } else {
            return await withCheckedContinuation { continuation in
                CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                    continuation.resume(returning: placemarks?.first?.timeZone)
                }
            }
        }
    }
}

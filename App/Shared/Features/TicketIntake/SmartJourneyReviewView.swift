import SwiftUI
import TrainTrackerCore

/// Review for every import source. A complete ticket searches immediately and reaches a single
/// Track Journey confirmation; an incomplete one asks only for what is missing. Presented inside
/// a `NavigationStack` owned by the caller.
struct SmartJourneyReviewView: View {
    @State private var store: SmartJourneyReviewStore?
    private let makeStore: @MainActor () -> SmartJourneyReviewStore

    let ticketDetails: TicketTextDetails?
    let onSaved: (TrackedJourneyPlan, Bool) -> Void
    let onOpenExisting: (TrackedJourneyPlan) -> Void
    let onClose: () -> Void

    /// The review store and search client are created once, when the screen first appears,
    /// not every time a parent view re-renders.
    init(
        suggestion: TicketRouteSuggestion,
        ticketDetails: TicketTextDetails? = nil,
        linkedPlanIDs: Set<UUID> = [],
        planLibrary: JourneyPlanLibrary,
        makeClient: @escaping @MainActor () -> any JourneySearching = { JourneySearchClient() },
        onDraftChange: ((TicketRouteSuggestion) -> Void)? = nil,
        onSaved: @escaping (TrackedJourneyPlan, Bool) -> Void,
        onOpenExisting: @escaping (TrackedJourneyPlan) -> Void,
        onClose: @escaping () -> Void
    ) {
        makeStore = {
            let store = SmartJourneyReviewStore(
                suggestion: suggestion, client: makeClient(), planTracker: planLibrary,
                plans: { planLibrary.plans }, linkedPlanIDs: linkedPlanIDs
            )
            store.onDraftChange = onDraftChange
            return store
        }
        self.ticketDetails = ticketDetails
        self.onSaved = onSaved
        self.onOpenExisting = onOpenExisting
        self.onClose = onClose
    }

    var body: some View {
        if let store {
            SmartJourneyReviewContent(
                store: store, ticketDetails: ticketDetails,
                onSaved: onSaved, onOpenExisting: onOpenExisting, onClose: onClose
            )
        } else {
            Color.ttBackgroundCanvas
                .onAppear { store = makeStore() }
        }
    }
}

/// Suggestions stay beside the active field, within the review's existing grouped form.
private struct SmartJourneyStationField: View {
    let field: SmartJourneyReviewStore.Field
    let store: SmartJourneyReviewStore
    let focus: FocusState<SmartJourneyReviewStore.Field?>.Binding

    private enum LookupState {
        case idle, loading, failed
        case results([RailPlace])
    }

    private struct LookupKey: Equatable {
        let query: String
        let focused: Bool
        let selection: RailIdentifier?
        let retry: Int
    }

    @State private var state: LookupState = .idle
    @State private var activeQuery: String?
    @State private var retry = 0

    private var isOrigin: Bool { field == .origin }
    private var isFocused: Bool { focus.wrappedValue == field }
    private var text: String { isOrigin ? store.origin : store.destination }
    private var selected: RailPlace? { isOrigin ? store.originPlace : store.destinationPlace }
    private var query: String { RailPlacePickerSearchPolicy.normalized(text) }
    private var lookupKey: LookupKey {
        LookupKey(query: query, focused: isFocused, selection: selected?.id, retry: retry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            HStack(spacing: TrainTrackerSpacing.space8) {
                TextField(
                    isOrigin ? "Departure station" : "Arrival station",
                    text: Binding(get: { text }, set: setText), axis: .vertical
                )
                .lineLimit(1...3)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused(focus, equals: field)
                .submitLabel(.done)
                .onSubmit { focus.wrappedValue = nil }
                .accessibilityIdentifier(isOrigin ? "smartReviewOrigin" : "smartReviewDestination")
                .accessibilityHint("Type a station or city name, then choose a suggested station")
                if isFocused, !text.isEmpty {
                    Button {
                        setText("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.ttTextSecondary)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isOrigin ? "Clear departure station" : "Clear arrival station")
                } else if selected != nil {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(Color.ttRouteActive)
                        .accessibilityLabel("Recognized station")
                }
            }
            .frame(minHeight: 44)

            if isFocused, selected == nil {
                Divider()
                suggestions
            }
        }
        .onChange(of: isFocused) { _, focused in
            if focused { store.revealStationField(field) }
        }
        .task(id: lookupKey) {
            await loadSuggestions()
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        if !RailPlacePickerSearchPolicy.shouldSearch(query) {
            Text("Type at least 2 letters of a station or city name.")
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
        } else if activeQuery == query {
            switch state {
            case .idle, .loading:
                ProgressView("Finding stations…")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
            case .failed:
                Text("Couldn't load stations. Check your connection and try again.")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
                Button("Try Again") { retry += 1 }
                    .buttonStyle(.borderless)
            case let .results(places):
                if places.isEmpty {
                    Text("No matching stations. Try a city name or another spelling.")
                        .font(.subheadline)
                        .foregroundStyle(Color.ttTextSecondary)
                } else {
                    ForEach(Array(places.prefix(5))) { place in
                        stationRow(place)
                    }
                    if places.count > 5 {
                        Text("Keep typing to narrow the stations.")
                            .font(.subheadline)
                            .foregroundStyle(Color.ttTextSecondary)
                    }
                }
            }
        }
    }

    private func stationRow(_ place: RailPlace) -> some View {
        let presentation = RailPlacePickerPresentation(place: place)
        let detail = stationLocation(place)
        return Button {
            store.selectStation(place, for: field)
            focus.wrappedValue = nil
        } label: {
            HStack(alignment: .top, spacing: TrainTrackerSpacing.space12) {
                Image(systemName: presentation.systemImage)
                    .foregroundStyle(Color.ttRouteActive)
                    .frame(width: LayoutMetrics.iconRailWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                    Text(presentation.title)
                        .foregroundStyle(Color.ttTextPrimary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Color.ttTextSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, TrainTrackerSpacing.space4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(presentation.title), \(detail)")
        .accessibilityHint(isOrigin ? "Use as departure station" : "Use as arrival station")
        .accessibilityIdentifier("smartReviewStationSuggestion-\(field.rawValue)-\(place.id.rawValue)")
    }

    private func stationLocation(_ place: RailPlace) -> String {
        let context = place.context.trimmingCharacters(in: .whitespacesAndNewlines)
        let country = Locale.autoupdatingCurrent.localizedString(forRegionCode: place.countryCode.uppercased()) ?? place.countryCode
        var details: [String] = []
        if !context.isEmpty, context != place.timeZoneIdentifier,
           context.caseInsensitiveCompare(place.countryCode) != .orderedSame,
           context.caseInsensitiveCompare(country) != .orderedSame,
           context != JourneySearchCopy.PlacePicker.allStations {
            details.append(context)
        }
        if !place.countryCode.isEmpty {
            details.append(country)
        }
        return details.isEmpty ? JourneySearchCopy.PlacePicker.station : details.joined(separator: " · ")
    }

    private func setText(_ value: String) {
        if isOrigin { store.setOrigin(value) } else { store.setDestination(value) }
    }

    private func loadSuggestions() async {
        let key = lookupKey
        activeQuery = key.query
        state = .idle
        guard key.focused, key.selection == nil,
              RailPlacePickerSearchPolicy.shouldSearch(key.query) else { return }
        state = .loading
        do {
            try await Task.sleep(for: RailPlacePickerSearchPolicy.debounce)
            try Task.checkCancellation()
            let places = try await store.stationSuggestions(for: key.query)
            try Task.checkCancellation()
            guard lookupKey == key else { return }
            state = .results(places)
        } catch is CancellationError {
            // A new query, another field, or closing the review owns the next state.
        } catch {
            guard !Task.isCancelled, lookupKey == key else { return }
            state = .failed
        }
    }
}

private struct SmartJourneyReviewContent: View {
    @Environment(JourneyPlanLibrary.self) private var planLibrary
    @FocusState private var focusedField: SmartJourneyReviewStore.Field?
    let store: SmartJourneyReviewStore
    let ticketDetails: TicketTextDetails?
    let onSaved: (TrackedJourneyPlan, Bool) -> Void
    let onOpenExisting: (TrackedJourneyPlan) -> Void
    let onClose: () -> Void

    var body: some View {
        content
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        store.cancelMatching()
                        onClose()
                    }
                        .accessibilityHint("Keeps this import in Unfinished so you can finish it later")
                }
                if store.stage == .matching, !isCompleted {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit Details", action: store.editDetails)
                            .accessibilityIdentifier("smartReviewEditDetails")
                    }
                }
            }
            .task { store.start() }
            .onDisappear { store.cancelMatching() }
    }

    private var isCompleted: Bool {
        if case .completed = store.search.phase { return true }
        return false
    }

    private var navigationTitle: String {
        switch store.stage {
        case .details: "Review Journey"
        case .existing: "Already Saved"
        case .matching:
            store.search.phase == .showingOutbound ? "Choose Your Train" : "Review Journey"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.stage {
        case let .details(notice):
            detailsForm(notice)
        case let .existing(planID):
            existingContent(planLibrary.plans.first { $0.id == planID })
        case .matching:
            matchingContent
        }
    }

    // MARK: - Details

    private func detailsForm(_ notice: SmartJourneyReviewStore.Notice?) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                    Text(routeSummary)
                        .font(.headline)
                        .foregroundStyle(Color.ttTextPrimary)
                    Text(store.suggestion.sourceDescription)
                        .font(.subheadline)
                        .foregroundStyle(Color.ttTextSecondary)
                }
                .accessibilityElement(children: .combine)
                if let notice {
                    SmartJourneyReviewNotice(notice: notice, store: store)
                }
            }
            .trainTrackerRowSurface()

            let fields = store.visibleFields
            if !fields.isEmpty {
                Section {
                    ForEach(fields) { field in
                        fieldRow(field)
                    }
                    if store.showsAllFields {
                        TextField("Train number (optional)", text: Binding(get: { store.trainNumber }, set: store.setTrainNumber))
                            .textInputAutocapitalization(.characters)
                            .accessibilityIdentifier("smartReviewTrainNumber")
                    }
                } header: {
                    Text(store.showsAllFields ? "Journey Details" : "Needed From Your Ticket")
                } footer: {
                    if let zone = store.departureTimeZone {
                        Text("Times are shown in \(zone.localizedName(for: .generic, locale: .autoupdatingCurrent) ?? zone.identifier).")
                    } else {
                        Text("Use the local time printed on your ticket. It's matched to the departure station's time zone.")
                    }
                }
                .trainTrackerRowSurface()
            }

            if let extracted = extractedSummary {
                Section("Saved From Your Ticket") {
                    Text(extracted)
                        .font(.subheadline)
                        .foregroundStyle(Color.ttTextSecondary)
                }
                .trainTrackerRowSurface()
            }

            Section {
                Button {
                    focusedField = nil
                    store.beginMatching()
                } label: {
                    Text(notice == .pastDeparture ? "Search Anyway" : "Find Train")
                        .trainTrackerFullWidthAction()
                }
                .trainTrackerPrimaryAction()
                .controlSize(.large)
                .disabled(!store.canBeginMatching)
                .accessibilityIdentifier("smartReviewFindTrain")
                if !store.showsAllFields {
                    Button {
                        store.showsAllFields = true
                    } label: {
                        Text("Edit All Details").trainTrackerFullWidthAction()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("smartReviewEditAll")
                }
            } footer: {
                Text("Station suggestions send the station names you type to the train search. Find Train sends the stations and departure time. Ticket contents stay on this device. Nothing is tracked until you confirm.")
            }
            .trainTrackerFormActionRow()
        }
        .formStyle(.grouped)
        .trainTrackerListCanvas()
    }

    @ViewBuilder
    private func fieldRow(_ field: SmartJourneyReviewStore.Field) -> some View {
        switch field {
        case .origin:
            SmartJourneyStationField(field: field, store: store, focus: $focusedField)
        case .destination:
            SmartJourneyStationField(field: field, store: store, focus: $focusedField)
        case .date:
            if store.departure == nil {
                Button("Set Travel Date") {
                    let today = TicketWallClock(date: .now, timeZone: store.knownTimeZone ?? .autoupdatingCurrent, includesTime: false)
                    store.setDay(year: today.year, month: today.month, day: today.day)
                }
                .accessibilityIdentifier("smartReviewSetDate")
            } else {
                DatePicker("Travel date", selection: dayBinding, displayedComponents: .date)
                    .environment(\.timeZone, Self.wallClockZone)
                    .accessibilityIdentifier("smartReviewDate")
            }
        case .time:
            if store.departure == nil {
                Text("Choose the travel date first.")
                    .foregroundStyle(Color.ttTextSecondary)
            } else if store.departure?.hasTime != true {
                Button("Set Departure Time") { store.setTime(hour: 9, minute: 0) }
                    .accessibilityIdentifier("smartReviewSetTime")
            } else {
                DatePicker("Departure time", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .environment(\.timeZone, Self.wallClockZone)
                    .accessibilityIdentifier("smartReviewTime")
                if store.requiresTimeCheck {
                    Toggle("Time checked against my ticket", isOn: Binding(get: { store.timeChecked }, set: store.setTimeChecked))
                        .accessibilityIdentifier("smartReviewTimeChecked")
                }
            }
        }
    }

    private static let wallClockZone = TimeZone(secondsFromGMT: 0) ?? .gmt

    private var dayBinding: Binding<Date> {
        Binding(
            get: { store.departure?.date(in: Self.wallClockZone) ?? .now },
            set: { value in
                let parts = TicketWallClock.calendar(Self.wallClockZone).dateComponents([.year, .month, .day], from: value)
                guard let year = parts.year, let month = parts.month, let day = parts.day else { return }
                store.setDay(year: year, month: month, day: day)
            }
        )
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { store.departure?.date(in: Self.wallClockZone) ?? .now },
            set: { value in
                let parts = TicketWallClock.calendar(Self.wallClockZone).dateComponents([.hour, .minute], from: value)
                guard let hour = parts.hour, let minute = parts.minute else { return }
                store.setTime(hour: hour, minute: minute)
            }
        )
    }

    private var routeSummary: String {
        let from = store.origin.isEmpty ? "Departure station needed" : store.origin
        let to = store.destination.isEmpty ? "arrival station needed" : store.destination
        return "\(from) → \(to)"
    }

    private var departureSummary: String? {
        guard let departure = store.departure, let date = departure.date(in: Self.wallClockZone) else { return nil }
        var style = Date.FormatStyle(date: .abbreviated, time: departure.hasTime ? .shortened : .omitted)
        style.timeZone = Self.wallClockZone
        return date.formatted(style)
    }

    private var extractedSummary: String? {
        guard let ticketDetails else { return nil }
        let parts = [
            ticketDetails.coach.map { "Coach \($0)" },
            ticketDetails.seat.map { "Seat \($0)" },
            ticketDetails.bookingReference.map { "Booking \($0)" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Matching

    @ViewBuilder
    private var matchingContent: some View {
        let search = store.search
        switch search.phase {
        case .showingOutbound:
            if let page = search.outboundPage {
                JourneyResultsView(
                    direction: .outbound,
                    context: JourneyResultsContext(direction: .outbound, form: search.form),
                    page: page,
                    options: search.visibleOutboundOptions,
                    preferredTrainNumber: search.preferredTrainNumber,
                    directOnly: search.form.directOnly,
                    maximumTransfers: search.form.maximumTransfers,
                    onDirectOnlyChanged: search.setDirectOnly,
                    onMaximumTransfersChanged: { search.rerunWithMaximumTransfers($0, direction: .outbound) },
                    onSelect: search.selectOutbound,
                    onLoadEarlier: search.loadEarlierOutbound,
                    onLoadLater: search.loadLaterOutbound
                )
                .safeAreaInset(edge: .top, spacing: 0) {
                    matchingBanner(message: search.importedReviewMessage ?? "Choose the train on your ticket to review it.")
                }
            } else {
                matchingProgress
            }
        case .reviewing, .resolving, .failed(.resolutionUnavailable), .failed(.trackingTokenExpired):
            if let option = search.selectedOutbound, let existing = store.existingPlan(forSelected: option) {
                existingContent(existing, canChooseAnother: search.canReturnToOutboundResults)
            } else {
                RoundTripReviewView(store: search, onTracked: { planID in
                    guard let plan = planLibrary.plans.first(where: { $0.id == planID }) else { return }
                    onSaved(plan, store.wasCreated(planID: planID))
                }, offersTicketPurchase: false)
                .navigationTitle("Review Journey")
                .toolbar {
                    if search.canReturnToOutboundResults {
                        ToolbarItem(placement: .bottomBar) {
                            // Text, not a bare symbol: the bottom bar would otherwise show an unlabeled icon.
                            Button("Choose Another Train", action: search.returnToOutboundResults)
                            .accessibilityHint("Returns to the fetched departures without starting a new search")
                            .accessibilityIdentifier("smartReviewChooseAnother")
                        }
                    }
                }
            }
        case .failed(.outboundSearchUnavailable):
            failureContent
        case .completed:
            // The sheet closes on save; until it does, confirm rather than flash "Finding".
            matchingStatus(isFinished: true)
        default:
            matchingProgress
        }
    }

    private func matchingBanner(message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(Color.ttTextSecondary)
            .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, LayoutMetrics.pageInset)
            .padding(.vertical, TrainTrackerSpacing.space12)
            .frame(maxWidth: .infinity)
            .background(.bar)
    }

    private var matchingProgress: some View {
        matchingStatus(isFinished: false)
    }

    private func matchingStatus(isFinished: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
                HStack(spacing: TrainTrackerSpacing.space12) {
                    if isFinished {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.ttStatusOnTime)
                            .accessibilityHidden(true)
                        Text("Added to My Trips")
                            .font(.headline)
                    } else {
                        ProgressView()
                        Text("Finding your train")
                            .font(.headline)
                    }
                }
                Text(routeSummary)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let departureSummary {
                    Text(departureSummary)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color.ttTextSecondary)
                }
                if !isFinished {
                    Text("Searching with the stations and departure time only. Ticket contents stay on this device.")
                        .font(.footnote)
                        .foregroundStyle(Color.ttTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LayoutMetrics.cardInset)
            .trainTrackerSurface(radius: TrainTrackerRadius.group)
            .accessibilityElement(children: .combine)
            .frame(maxWidth: LayoutMetrics.contentMaxWidth)
            .padding(LayoutMetrics.pageInset)
            .frame(maxWidth: .infinity)
        }
        .background(Color.ttBackgroundCanvas)
    }

    private var failureContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                Label("Couldn't search for trains", systemImage: store.search.journeyFailureReason == .offline ? "wifi.exclamationmark" : "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(Color.ttStatusDelayed)
                Text(JourneySearchCopy.Form.searchFailureMessage(for: store.search.journeyFailureReason))
                    .font(.subheadline)
                Text("Your ticket details are saved on this device.")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
                Button {
                    store.retry()
                } label: {
                    Text("Try Again").frame(maxWidth: .infinity, minHeight: 44)
                }
                .trainTrackerPrimaryAction()
                .accessibilityIdentifier("smartReviewRetry")
                Button {
                    store.editDetails()
                } label: {
                    Text("Edit Details").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LayoutMetrics.cardInset)
            .trainTrackerSurface(radius: TrainTrackerRadius.group)
            .frame(maxWidth: LayoutMetrics.contentMaxWidth)
            .padding(LayoutMetrics.pageInset)
            .frame(maxWidth: .infinity)
        }
        .background(Color.ttBackgroundCanvas)
    }

    // MARK: - Existing

    @ViewBuilder
    private func existingContent(_ plan: TrackedJourneyPlan?, canChooseAnother: Bool = false) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                Label("Already in My Trips", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Color.ttStatusOnTime)
                if let plan {
                    Text("\(plan.origin.displayName) → \(plan.destination.displayName)")
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(JourneyExperienceClock.date(plan.outbound.departure, zone: plan.origin.timeZoneIdentifier)
                         + " · " + JourneyExperienceClock.time(plan.outbound.departure, zone: plan.origin.timeZoneIdentifier))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color.ttTextSecondary)
                    Text("This journey is already saved, so it won't be added again.")
                        .font(.subheadline)
                        .foregroundStyle(Color.ttTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        onOpenExisting(plan)
                    } label: {
                        Text("Open Journey").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .trainTrackerPrimaryAction()
                    .accessibilityIdentifier("smartReviewOpenExisting")
                } else {
                    Text("The saved journey is no longer available.")
                        .font(.subheadline)
                }
                if canChooseAnother {
                    Button {
                        store.search.returnToOutboundResults()
                    } label: {
                        Text("Choose Another Train").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Edit Details", action: store.editDetails)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LayoutMetrics.cardInset)
            .trainTrackerSurface(radius: TrainTrackerRadius.group)
            .frame(maxWidth: LayoutMetrics.contentMaxWidth)
            .padding(LayoutMetrics.pageInset)
            .frame(maxWidth: .infinity)
        }
        .background(Color.ttBackgroundCanvas)
    }
}

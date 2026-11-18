import SwiftUI
import TrainTrackerCore

struct JourneyRecoveryTicket: View {
    @Environment(TripLibrary.self) private var trips
    @Environment(JourneyPlanLibrary.self) private var plans
    @Environment(AppNavigationModel.self) private var navigation
    @Environment(\.journeyReferenceDate) private var fixtureClock
    @State private var store: JourneyRecoveryStore
    @State private var followTask: Task<Void, Never>?

    let planID: UUID
    let request: JourneyRecoveryRequest
    let connection: JourneyPlanStage.Connection?
    let referenceDate: Date

    init(planID: UUID, request: JourneyRecoveryRequest, connection: JourneyPlanStage.Connection?, referenceDate: Date) {
        self.planID = planID
        self.request = request
        self.connection = connection
        self.referenceDate = referenceDate
        #if DEBUG
        if LaunchFixtures.isActive {
            _store = State(initialValue: JourneyRecoveryStore(client: JourneyRecoveryPreview()))
            return
        }
        #endif
        _store = State(initialValue: JourneyRecoveryStore())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                Label(connection == nil ? "Cancelled train" : connection?.isMissed == true
                      ? "Connection may be missed" : "Tight connection", systemImage: "arrow.triangle.swap")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ttStatusDelayed)
                Text(request.origin.displayName)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                if let connection {
                    if let minutes = connection.estimatedMinutes, minutes > 0 {
                        Text("\(minutes) min between trains")
                            .font(.body.weight(.medium).monospacedDigit())
                    }
                    if let service = connection.next.serviceName,
                       let first = JourneyRecoveryRequest.progress(connection.next, trips: trips.trips, at: referenceDate)?.stops.first,
                       let departure = first.expectedDeparture ?? first.scheduledDeparture {
                        let basis = first.expectedDeparture == nil ? "scheduled" : "estimated"
                        Text("\(service) · \(basis) \(time(departure, at: connection.next.from))")
                            .font(.subheadline.monospacedDigit())
                    }
                    if let platforms = transferPlatforms(connection) { Text(platforms).font(.subheadline) }
                    if connection.walkMinutes > 0 {
                        Text("Planned walk · \(connection.walkMinutes) min").font(.subheadline)
                    }
                }
            }
            Divider()
            if let timetable = connection?.timetable {
                ConnectionTimetableView(timetable: timetable, showsAvailableInterval: (connection?.estimatedMinutes ?? 0) <= 0)
                Divider()
            }
            switch store.result {
            case .loading:
                Text("Checking later trains…").font(.subheadline)
            case .empty:
                Text("No reachable alternative in these results.").font(.subheadline)
            case .unavailable:
                Text("Later departures couldn’t be checked.").font(.subheadline)
            case .candidate(let candidate):
                candidateDetails(candidate)
            }

            if let message = store.saveMessage {
                Text(message).font(.footnote).foregroundStyle(Color.ttTextSecondary)
            }
            Button("Search Other Trains") {
                navigation.openTicketJourneySearch(request.searchRequest(at: referenceDate))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.ttActionTint)
            .accessibilityIdentifier("searchConnectionAlternatives")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Color.ttTextPrimary)
        .padding(LayoutMetrics.cardInset)
        .trainTrackerSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectionRecoveryTicket")
        .task { await store.load(request, at: referenceDate) }
        .onChange(of: referenceDate) { _, date in
            Task { await store.load(request, at: date) }
        }
        .onDisappear { followTask?.cancel() }
    }

    @ViewBuilder
    private func candidateDetails(_ candidate: JourneyRecoveryOption) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
            Text("Next option to \(request.destination.displayName)")
                .font(.subheadline).foregroundStyle(Color.ttTextSecondary)
            Text("\(time(candidate.departure, at: candidate.firstTrain.from.place)) · \(candidate.service)")
                .font(.headline.monospacedDigit())
                .accessibilityIdentifier("connectionAlternativeService")
            if !JourneyTransferStation.matches(candidate.firstTrain.from.place, request.origin) {
                Text("Board at \(candidate.firstTrain.from.place.displayName)").font(.subheadline)
            }
            if candidate.option.transferCount > 0 {
                Text(candidate.option.transferCount == 1 ? "1 more change" : "\(candidate.option.transferCount) more changes")
                    .font(.subheadline)
            }
            let source = candidate.estimated ? "Estimated departure" : "Timetable departure"
            Text("\(source) · Checked \(time(candidate.generatedAt, at: request.origin))")
                .font(.caption).foregroundStyle(Color.ttTextSecondary)
            Text("Following keeps your original booking. Check ticket validity with the operator.")
                .font(.caption).foregroundStyle(Color.ttTextSecondary)
        }
        let id = JourneyRecoveryStore.planID(for: candidate, basedOn: planID)
        if plans.plans.contains(where: { $0.id == id }) {
            Button {
                navigation.open(.journey(id))
            } label: {
                Label("View Followed Alternative", systemImage: "checkmark")
                    .foregroundStyle(Color.ttActionTint)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("viewFollowedAlternative")
        } else {
            Button {
                followTask = Task {
                    await store.follow(candidate, request: request, planID: planID, in: plans) { fixtureClock ?? .now }
                }
            } label: {
                Text(store.isSaving ? "Checking Train…" : "Follow Alternative")
                    .foregroundStyle(Color.ttTextOnBrand)
            }
            .trainTrackerPrimaryAction()
            .controlSize(.large)
            .disabled(store.isSaving)
            .accessibilityHint("Follows these trains separately and keeps your original booking.")
            .accessibilityIdentifier("followConnectionAlternative")
        }
    }

    private func transferPlatforms(_ connection: JourneyPlanStage.Connection) -> String? {
        let incoming = JourneyRecoveryRequest.progress(connection.previous, trips: trips.trips, at: referenceDate)?.stops.last
        let outgoing = JourneyRecoveryRequest.progress(connection.next, trips: trips.trips, at: referenceDate)?.stops.first
        guard let incoming, let outgoing, let a = incoming.displayPlatform, let b = outgoing.displayPlatform else { return nil }
        let noun = incoming.platformNoun == "Track" && outgoing.platformNoun == "Track" ? "tracks" : "platforms"
        if incoming.expectedPlatform != nil && outgoing.expectedPlatform != nil {
            return "Last reported \(noun) · \(a) → \(b)"
        }
        if incoming.expectedPlatform == nil && outgoing.expectedPlatform == nil {
            return "Planned \(noun) · \(a) → \(b)"
        }
        let from = incoming.expectedPlatform == nil ? "Planned" : "Last reported"
        let to = outgoing.expectedPlatform == nil ? "planned" : "last reported"
        return "\(from) \(incoming.platformNoun.lowercased()) \(a) → \(to) \(outgoing.platformNoun.lowercased()) \(b)"
    }

    private func time(_ date: Date, at place: RailPlace) -> String {
        let time = JourneyPlanDateTimePresentation.labeledTime(date, timeZoneIdentifier: place.timeZoneIdentifier)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: place.timeZoneIdentifier) ?? .gmt
        if calendar.isDate(date, inSameDayAs: referenceDate) { return time }
        return JourneyPlanDateTimePresentation.date(date, timeZoneIdentifier: place.timeZoneIdentifier) + " · " + time
    }
}

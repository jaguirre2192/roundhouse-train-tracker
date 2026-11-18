import SwiftUI
import TrainTrackerCore

/// A station sign at phone width. On an unfolded screen it occupies the same leading
/// column as the journey sheet, leaving the route and camera controls beside it.
struct PlatformBoardView: View {
    let experience: JourneyExperiencePresentation
    @Environment(TripLibrary.self) private var library
    @Environment(JourneyPlanLibrary.self) private var plans: JourneyPlanLibrary?
    @Environment(LocalJourneyTicketStore.self) private var vault
    @Environment(\.journeyReferenceDate) private var fixtureDate
    @Environment(\.scenePhase) private var scenePhase
    @State private var openTicket: LocalJourneyTicket?
    @State private var selectedTicketID: UUID?

    var body: some View {
        GeometryReader { proxy in
            let space = JourneyPanelGeometry(proxy)
            TimelineView(.periodic(from: .now, by: 10)) { timeline in
                let trip = library.trip(id: experience.trip.id).flatMap { $0.serviceDate == experience.trip.serviceDate ? $0 : nil }
                let current = trip.map { updated in
                    JourneyExperiencePresentation(
                        trip: updated, timeZones: experience.timeZones, referenceDate: fixtureDate ?? timeline.date,
                        lastSuccessfulCheck: library.lastSuccessfulCheck(for: updated.id),
                        refreshFailed: library.lastRefreshFailed(for: updated.id), selectedSegment: experience.selectedSegment
                    )
                }
                let board = current.flatMap {
                    PlatformBoardPresentation(experience: $0, journal: library.changeJournal(for: $0.trip.id),
                                              watching: library.isWatchingOnly($0.trip.id), plans: plans?.plans ?? [])
                }
                let tickets = PlatformBoardTicket.matching(vault.tickets, tripID: experience.trip.id, plans: plans?.plans ?? [])
                ZStack(alignment: .topLeading) {
                    if space.floatsBeside, let trip {
                        TripRouteMapView(trip: trip, fillsScreen: true, leadingInset: space.mapLeadingInset)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("platformRouteMap")
                    } else {
                        Color.ttBackgroundBrand.ignoresSafeArea()
                    }
                    PlatformStationSign(board: board, service: LiveLineTicketPresentation.serviceName(for: experience.trip),
                                        hasRoomForLargeNumber: !space.floatsBeside && space.height >= 620,
                                        tickets: tickets, selection: $selectedTicketID, openTicket: { openTicket = $0 })
                        .frame(width: space.floatsBeside ? space.panelWidth : nil,
                               height: space.floatsBeside ? space.maximumPanelHeight : nil)
                        .background(Color.ttBackgroundBrand)
                        .clipShape(RoundedRectangle(cornerRadius: space.floatsBeside ? TrainTrackerRadius.hero : 0))
                        .padding(space.floatsBeside ? JourneyPanelGeometry.margin : 0)
                }
                .navigationTitle(space.floatsBeside ? "" : "Platform View")
                .toolbarBackground(space.floatsBeside ? .hidden : .visible, for: .navigationBar)
                .toolbarBackground(Color.ttBackgroundBrand, for: .navigationBar)
                .toolbarColorScheme(space.floatsBeside ? nil : .dark, for: .navigationBar)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $openTicket) { ticket in PlatformBoardOriginal(ticket: ticket) }
        .task(id: experience.trip.id) {
            guard fixtureDate == nil else { return }
            while !Task.isCancelled {
                if scenePhase == .active { await library.refreshTrackedTrip(id: experience.trip.id, allowEnded: false) }
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
    }
}

private struct PlatformStationSign: View {
    let board: PlatformBoardPresentation?
    let service: String
    let hasRoomForLargeNumber: Bool
    let tickets: [PlatformBoardTicket]
    @Binding var selection: UUID?
    let openTicket: (LocalJourneyTicket) -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var fullHeightNumeralSize = 162
    @ScaledMetric(relativeTo: .largeTitle) private var panelNumeralSize = 114
    @ScaledMetric(relativeTo: .largeTitle) private var longNumberSize = 56
    @ScaledMetric(relativeTo: .title) private var oldNumeralSize = 42
    private var paper: Color { .ttTextOnBrand }
    private var muted: Color { paper.opacity(0.76) }
    private var selected: PlatformBoardTicket? {
        tickets.count == 1 ? tickets.first : tickets.first { $0.id == selection }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space24) {
                if let board {
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                        Text(service).font(.subheadline.weight(.semibold)).foregroundStyle(muted)
                        Text(board.station).font(.title.weight(.bold))
                            .accessibilityIdentifier("platformStation")
                    }
                    rule
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                        Text([board.stationTerm, board.previous == nil ? board.noun : "\(board.noun) changed"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.headline).foregroundStyle(muted)
                        if let number = board.number {
                            numbers(number, previous: board.previous)
                        } else {
                            Text("Awaiting assignment").font(.largeTitle.bold())
                                .accessibilityIdentifier("platformAwaiting")
                        }
                        Text(board.sourceText).font(.footnote).foregroundStyle(muted)
                    }
                    rule
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space20) {
                            details(board).fixedSize(horizontal: true, vertical: false)
                        }
                        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) { details(board) }
                    }
                } else {
                    Text("Boarding details unavailable").font(.title.bold())
                    Text("Open the journey for the latest train details.").foregroundStyle(muted)
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LayoutMetrics.pageInset)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            if !tickets.isEmpty {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    if tickets.count > 1 {
                        Picker("Saved ticket", selection: $selection) {
                            Text("Choose a ticket").tag(UUID?.none)
                            ForEach(tickets) { choice in
                                Text(choice.ticket.filename ?? choice.ticket.title).tag(Optional(choice.id))
                            }
                        }
                        .tint(paper)
                    }
                    if let selected {
                        Button { openTicket(selected.ticket) } label: {
                            Label("Show Ticket", systemImage: "ticket").font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 38)
                        }
                        .buttonStyle(.borderedProminent).tint(paper)
                        .foregroundStyle(Color.ttBackgroundBrand)
                        .accessibilityIdentifier("platformShowTicket")
                    }
                }
                .padding(LayoutMetrics.pageInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.ttBackgroundBrand)
            }
        }
        .foregroundStyle(paper)
    }

    private var rule: some View { Rectangle().fill(paper.opacity(0.24)).frame(height: 1).accessibilityHidden(true) }

    @ViewBuilder private func numbers(_ current: String, previous: String?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space12) {
                numerals(current, previous: previous).fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 0) { numerals(current, previous: previous) }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(previous.map { "Changed from \($0) to \(current)" } ?? current)
        .accessibilityIdentifier("platformNumber")
    }

    @ViewBuilder private func numerals(_ current: String, previous: String?) -> some View {
        if let previous {
            HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space8) {
                Text(previous).font(.system(size: oldNumeralSize, weight: .medium)).strikethrough()
                Image(systemName: "arrow.forward").font(.headline)
            }
            .foregroundStyle(muted)
        }
        let size = hasRoomForLargeNumber ? fullHeightNumeralSize : panelNumeralSize
        Text(current).font(.system(size: current.count > 3 ? longNumberSize : size, weight: .bold, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func details(_ board: PlatformBoardPresentation) -> some View {
        field(board.departureLabel, board.departure)
        if let coach = selected?.coach { field("Coach", coach) }
        if let seat = selected?.seat { field("Seat", seat) }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(muted)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

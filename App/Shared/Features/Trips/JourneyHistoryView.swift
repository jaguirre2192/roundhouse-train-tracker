import SwiftUI
import TrainTrackerCore

/// Saved history is a destination, so old tickets never displace the train on home.
struct JourneyHistoryView: View {
    @Environment(TripLibrary.self) private var library
    @Environment(JourneyPlanLibrary.self) private var planLibrary
    @Environment(\.journeyReferenceDate) private var referenceDate
    @State private var travelLog = TravelLog.shared
    @State private var archive: JourneyHistoryArchive?

    private struct Sources: Equatable {
        let plans: [TrackedJourneyPlan]
        let trips: [TrainTrip]
        let watching: Set<RailIdentifier>
        let referenceDate: Date?
    }

    var body: some View {
        let sources = Sources(plans: planLibrary.plans, trips: library.trips, watching: library.watchingOnlyIDs, referenceDate: referenceDate)
        Group {
            if let archive {
                HistoryMonthsView(archive: archive, hasTravelLog: !travelLog.entries.isEmpty)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: sources) {
            var lastRoutes: Set<TripsRoute>?
            while !Task.isCancelled {
                let date = sources.referenceDate ?? .now
                let selection = JourneyHistorySelection(plans: sources.plans, trips: sources.trips, at: date)
                if lastRoutes != selection.routes {
                    archive = JourneyHistoryArchive(selection: selection, plans: sources.plans, watching: sources.watching)
                    lastRoutes = selection.routes
                }
                guard sources.referenceDate == nil, let next = selection.nextCheck else { return }
                do {
                    try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
                } catch { return }
            }
        }
        .navigationTitle("Past Journeys")
        .navigationBarTitleDisplayMode(.inline)
        .trainTrackerPageBackground()
    }
}

private struct HistoryMonthsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var minimumTicketWidth: CGFloat = 292
    @State private var query = ""
    @State private var contentBounds: ClosedRange<CGFloat> = 0...0
    @State private var screenDivision: ClosedRange<CGFloat>?
    @Environment(\.layoutDirection) private var layoutDirection
    let archive: JourneyHistoryArchive
    let hasTravelLog: Bool

    var body: some View {
        if archive.months.isEmpty && archive.watched.isEmpty {
            archiveScroll
        } else {
            archiveScroll
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Station, route or train")
        }
    }

    private var archiveScroll: some View {
        let months = archive.months(matching: query)
        let watched = archive.watched(matching: query)
        let featuredID = archive.featuredTicketID(matching: query)
        let columns = JourneySpreadColumns(content: contentBounds, division: screenDivision,
                                           minimum: max(280, minimumTicketWidth), rightToLeft: layoutDirection == .rightToLeft)
        let spread = dynamicTypeSize.isAccessibilitySize ? nil : columns
        let windowMidX = JourneySpreadColumns.innerLandscapeWindowMidX
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                if archive.months.isEmpty, archive.watched.isEmpty, !hasTravelLog {
                    ContentUnavailableView("No Past Journeys", systemImage: "clock.arrow.circlepath",
                        description: Text("Your saved journeys will appear here after their travel dates."))
                } else if !query.isEmpty, months.isEmpty, watched.isEmpty {
                    ContentUnavailableView {
                        Label("No Matching Journeys", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try a different station or train number.")
                    } actions: {
                        Button("Clear Search") { query = "" }
                            .accessibilityIdentifier("clearPastJourneySearch")
                    }
                }
                ForEach(JourneyHistoryArchive.rows(months, pairsSingles: spread != nil)) { row in
                    if let other = row.second, let spread {
                        HStack(alignment: .top, spacing: spread.gap) {
                            monthSection(row.first, featuredID: featuredID)
                                .frame(width: spread.first)
                            monthSection(other, featuredID: featuredID)
                                .frame(width: spread.second)
                        }
                    } else {
                        monthSection(row.first, featuredID: featuredID, spread: spread)
                    }
                }
                if hasTravelLog { TravelLogLink() }
                if !watched.isEmpty {
                    VStack(alignment: .leading, spacing: LayoutMetrics.rowSpacing) {
                        Label("Watched trains", systemImage: "eye")
                            .font(.headline)
                            .foregroundStyle(Color.ttTextSecondary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(watched) { ticket in
                            TripsRouteLink(route: ticket.route) {
                                JourneyHistoryTicketRow(ticket: ticket, featured: false)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(ticket.id)
                        }
                    }
                    .frame(maxWidth: spread?.first ?? .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
            .onGeometryChange(for: ClosedRange<CGFloat>.self) {
                let frame = $0.frame(in: .global)
                return frame.minX...frame.maxX
            } action: { contentBounds = $0 }
            .padding(LayoutMetrics.pageInset)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: ClosedRange<CGFloat>?.self) { proxy in
            JourneySpreadColumns.division(in: proxy, windowMidX: windowMidX)
        } action: { screenDivision = $0 }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("pastJourneysScroll")
    }

    private func monthSection(_ month: JourneyHistoryArchive.Month, featuredID: String?,
                              spread: JourneySpreadColumns? = nil) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            Text(month.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.ttTextPrimary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: spread?.gridItems ?? [GridItem(.flexible(), alignment: .top)],
                      alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                ForEach(month.tickets) { ticket in
                    TripsRouteLink(route: ticket.route) {
                        JourneyHistoryTicketRow(ticket: ticket, featured: ticket.id == featuredID)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(ticket.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct JourneyHistoryLink: View {
    let count: Int

    var body: some View {
        TripsRouteLink(route: .pastJourneys, marksSelection: false) {
            HStack(spacing: TrainTrackerSpacing.space12) {
                Label("Past Journeys", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: TrainTrackerSpacing.space8)
                if count > 0 {
                    Text(count, format: .number)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color.ttTextSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("pastJourneysFromHome")
        .accessibilityHint("Opens saved past journeys without changing the train on your map")
    }
}

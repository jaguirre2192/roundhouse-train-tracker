import AppIntents
import SwiftUI
import TrainTrackerCore

struct TripDetailView: View {
    @Environment(TripLibrary.self) private var library
    @Environment(JourneyPlanLibrary.self) private var planLibrary: JourneyPlanLibrary?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.journeyReferenceDate) private var referenceDate
    @Environment(\.scenePhase) private var scenePhase
    @State private var isConfirmingRemoval = false
    @State private var removalError = false
    @State private var shareURL: URL?
    @State private var shareError = false
    @State private var availableWidth: CGFloat = 0
    @State private var detent = JourneyDrawerDetent.half

    let trip: TrainTrip
    let routeTimeZones: JourneyPlanRouteTimeZones?
    let selectedSegment: JourneyPlanSegment?

    init(
        trip: TrainTrip,
        routeTimeZones: JourneyPlanRouteTimeZones? = nil,
        selectedSegment: JourneyPlanSegment? = nil
    ) {
        self.trip = trip
        self.routeTimeZones = routeTimeZones
        self.selectedSegment = selectedSegment
    }

    var body: some View {
        let trip = currentTrip
        Group {
            if usesMapBackdrop {
                detailChrome(mapBackdrop(trip), trip: trip, isMapBacked: true)
                    // The ticket names the train. Duo also keeps its upper-left map status
                    // clear when folding back to compact width.
                    .trainTrackerBarTitleHidden(horizontalSizeClass == .regular || TrainTrackerDevice.isDuo)
                    .trainTrackerShowSidebarButton()
            } else {
                detailChrome(detailScroll(trip), trip: trip)
                    // On regular width the ticket names the journey; a centred "Journey" adds nothing.
                    .trainTrackerBarTitleHidden(horizontalSizeClass == .regular)
                    .trainTrackerShowSidebarButton()
            }
        }
        .task(id: trip.id) {
            guard referenceDate == nil else { return }
            await prepareShareLink()
            await library.refreshTrackedTrip(id: trip.id, allowEnded: false)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) }
                catch { return }
                if scenePhase == .active { await library.refreshTrackedTrip(id: trip.id, allowEnded: false) }
            }
        }
        .onChange(of: scenePhase) { old, new in
            if old != .active, new == .active {
                Task { await library.refreshTrackedTrip(id: trip.id, allowEnded: false) }
            }
        }
        .savedTrainEntityContext(id: trip.id.rawValue)
    }

    /// The map leads at every width: the train and its route fill the screen. On a narrow one
    /// the journey rests over them in a panel with three heights; on a wide one it floats
    /// beside them. Only the largest text sizes keep the plain scrolling page, where a floating
    /// panel would leave too little room to read.
    private var usesMapBackdrop: Bool {
        horizontalSizeClass == .compact || !dynamicTypeSize.isAccessibilitySize
    }

    private func mapBackdrop(_ trip: TrainTrip) -> some View {
        MapBackedJourneyView(
            trip: trip, routeTimeZones: routeTimeZones, selectedSegment: selectedSegment, detent: $detent
        ) {
            EmptyView()
        } actions: {
            JourneyActionRow(
                shareURL: shareURL, shareSubject: "\(trip.product) train trip",
                stopTracking: { isConfirmingRemoval = true }
            )
        } extra: {
            EmptyView()
        }
    }

    private func detailScroll(_ trip: TrainTrip) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space24) {
                    WatchingTrainControl(trip: trip, selectedSegment: selectedSegment ?? JourneyTripContext.selectedSegment(for: trip.id, plans: planLibrary?.plans ?? []),
                                         hasEnded: presentation(for: trip, at: referenceDate ?? timeline.date).progress.phase == .ended)
                    let experience = presentation(for: trip, at: referenceDate ?? timeline.date)
                    WindowSeatLink(trip: trip, selectedStops: experience.progress.stops)
                    JourneyExperienceContent(presentation: experience)
                    if referenceDate == nil {
                        JourneyLiveActivityControls(trip: trip, selectedSegment: selectedSegment)
                    }
                    JourneyTicketsSection(owner: .trip(trip.id.rawValue))
                    MeetTrainAction(trip: trip, selectedSegment: selectedSegment ?? JourneyTripContext.selectedSegment(for: trip.id, plans: planLibrary?.plans ?? []))
                }
                    .frame(maxWidth: detailContentMaxWidth, alignment: .leading)
                    .padding(LayoutMetrics.pageInset)
                    .padding(.bottom, usesMapBackdrop ? 0 : LayoutMetrics.mobileFloatingBarClearance)
                    .frame(maxWidth: .infinity)
            }
            .refreshable { await library.refreshTrackedTrip(id: trip.id) }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        }
    }

    /// The journey's background, title, actions and dialogs, shared by the scrolling detail on
    /// regular width and the map-backed screen on compact width.
    private func detailChrome(_ content: some View, trip: TrainTrip, isMapBacked: Bool = false) -> some View {
        content
        .trainTrackerPageBackground(mood: JourneyMood(
            status: TripPresentationStatus(trip: trip, referenceDate: referenceDate ?? .now).kind,
            isConfirmed: TripFreshness(
                lastSuccessfulCheck: library.lastSuccessfulCheck(for: trip.id),
                lastRefreshFailed: library.lastRefreshFailed(for: trip.id)
            ).isConfirmed
        ))
        .navigationTitle(isMapBacked ? trip.product : "Journey")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isMapBacked {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await library.refreshTrackedTrip(id: trip.id) }
                } label: {
                    Label {
                        Text("Refresh journey")
                    } icon: {
                        RefreshStateLabel(isRefreshing: library.isRefreshing) { library.lastRefreshFailed(for: trip.id) }
                    }
                }
                .disabled(library.isRefreshing)
            }
            // Map screens keep refresh in the aligned map-control cluster; the scrolling
            // fallback retains the native toolbar actions.
            ToolbarItem(placement: .primaryAction) {
                if let shareURL {
                    ShareLink(
                        item: shareURL,
                        subject: Text("\(trip.product) train trip"),
                        message: Text("Add this train to Roundhouse. Ticket and passenger details are not shared.")
                    ) {
                        Label("Share Trip", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        Task { await prepareShareLink() }
                    } label: {
                        Label("Share Trip", systemImage: shareError ? "exclamationmark.arrow.triangle.2.circlepath" : "square.and.arrow.up")
                    }
                    .disabled(!shareError)
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Stop Tracking", systemImage: "trash", role: .destructive) {
                    isConfirmingRemoval = true
                }
            }
            }
        }
        .confirmationDialog(
            "Stop tracking this train?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Stop Tracking", role: .destructive) {
                if library.removeTrip(id: trip.id) {
                    dismiss()
                } else {
                    removalError = true
                }
            }
        } message: {
            Text("The trip will be removed and change notifications will stop. Any journey group that includes it will remain and show “No longer tracked.”")
        }
        .alert("Couldn’t stop tracking", isPresented: $removalError) {
            Button("OK") {}
        } message: {
            Text("The train is still tracked. Try again.")
        }
    }

    private func presentation(for trip: TrainTrip, at date: Date) -> JourneyExperiencePresentation {
        let segment = selectedSegment ?? JourneyTripContext.selectedSegment(
            for: trip.id, plans: planLibrary?.plans ?? []
        )
        let timeZones = TripDetailTimeZoneContext(
            trip: trip, routeTimeZones: routeTimeZones,
            plans: planLibrary?.plans ?? [],
            additionalPlaces: segment.map { [$0.from, $0.to] } ?? []
        )
        return JourneyExperiencePresentation(
            trip: trip, timeZones: timeZones, referenceDate: date,
            lastSuccessfulCheck: library.lastSuccessfulCheck(for: trip.id),
            refreshFailed: library.lastRefreshFailed(for: trip.id),
            selectedSegment: segment
        )
    }

    private func prepareShareLink() async {
        shareError = false
        do {
            shareURL = try await library.shareURL(for: currentTrip)
        } catch is CancellationError {
            return
        } catch {
            shareError = true
        }
    }

    /// Regular width fits two columns when there's room; otherwise (a detail beside the iPad
    /// sidebar) everything stacks in one centred column, so the ticket, map, stops and the
    /// sections below share both edges.
    private var detailContentMaxWidth: CGFloat {
        guard horizontalSizeClass == .regular else { return LayoutMetrics.contentMaxWidth }
        let columnWidth = availableWidth - LayoutMetrics.pageInset * 2
        return columnWidth >= JourneyExperienceContent.twoColumnMinimumWidth
            ? LayoutMetrics.desktopDetailMaxWidth
            : JourneyExperienceContent.stackedMaximumWidth
    }

    private var currentTrip: TrainTrip {
        library.trip(id: trip.id) ?? trip
    }
}

private extension View {
    @ViewBuilder
    func savedTrainEntityContext(id: String) -> some View {
        if #available(iOS 18.4, *) {
            appEntityIdentifier(EntityIdentifier(for: SavedTrainEntity.self, identifier: id))
        } else {
            self
        }
    }
}

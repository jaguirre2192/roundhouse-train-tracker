import SwiftUI
import TrainTrackerCore

@MainActor
struct JourneySearchView: View {
    @Environment(AppNavigationModel.self) private var navigation
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var store: JourneySearchStore
    @State private var recents: RailPlaceRecents
    @State private var openedFromTicket = false
    @State private var presentedPicker: RailPlacePickerRole?
    @State private var availableWidth: CGFloat = 0
    #if DEBUG
    private let resultsPreviewMode: JourneyResultsPreviewMode?
    private let reviewPreviewMode: JourneyReviewPreviewMode?
    private let liveRoundTripQAMode: JourneyLiveRoundTripQAMode?
    #endif

    init(
        planLibrary: JourneyPlanLibrary,
        client: any JourneySearching = JourneySearchClient(),
        recents: RailPlaceRecents = .standard
    ) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let resultsPreviewMode = JourneyResultsPreviewMode.resolve(arguments: arguments)
        let reviewPreviewMode = JourneyReviewPreviewMode.resolve(arguments: arguments)
        let liveRoundTripQAMode = JourneyLiveRoundTripQAMode.resolve(arguments: arguments)
        let japanesePreviewFixture = resultsPreviewMode == .japanese
            ? JourneyJapanesePreviewFixture()
            : nil
        let previewFixture = (
            (resultsPreviewMode != nil && resultsPreviewMode != .japanese)
                || reviewPreviewMode != nil
        )
            ? JourneyResultsPreviewFixture()
            : nil
        let effectiveClient: any JourneySearching
        if let japanesePreviewFixture {
            effectiveClient = JourneyJapanesePreviewClient(fixture: japanesePreviewFixture)
        } else if arguments.contains("-FrictionlessIntakeQA") {
            effectiveClient = FrictionlessIntakeQAClient()
        } else {
            effectiveClient = previewFixture.map {
                JourneyResultsPreviewClient(fixture: $0, reviewMode: reviewPreviewMode)
            } ?? client
        }
        self.resultsPreviewMode = resultsPreviewMode
        self.reviewPreviewMode = reviewPreviewMode
        self.liveRoundTripQAMode = liveRoundTripQAMode
        _store = State(initialValue: JourneySearchStore(
            client: effectiveClient,
            planTracker: planLibrary,
            form: japanesePreviewFixture?.form
                ?? previewFixture?.form
                ?? liveRoundTripQAMode?.form()
                ?? JourneySearchFormState()
        ))
        #else
        _store = State(initialValue: JourneySearchStore(
            client: client,
            planTracker: planLibrary
        ))
        #endif
        _recents = State(initialValue: recents)
    }

    var body: some View {
        Group {
            if usesSplitLayout && !usesWideLanding {
                splitContent
            } else {
                phaseContent
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(usesSplitLayout ? .inline : .automatic)
            .task {
                #if DEBUG
                await resultsPreviewMode?.bootstrap(store)
                await reviewPreviewMode?.bootstrap(store)
                await liveRoundTripQAMode?.bootstrap(store)
                #endif
            }
            .task(id: navigation.requestedTicketJourneySearch?.id) {
                guard let request = navigation.requestedTicketJourneySearch else {
                    // An empty form starts from the home station chosen in Settings.
                    if !openedFromTicket, store.form.origin == nil, store.form.destination == nil,
                       let home = HomeStationStore.standard.place {
                        store.setOrigin(home)
                    }
                    return
                }
                openedFromTicket = true
                await store.prefillTicketJourney(request)
                navigation.consumeTicketJourneySearch(ifMatching: request.id)
            }
            .sheet(item: $presentedPicker) { role in
                RailPlacePicker(role: role, store: store, recents: recents)
                    .presentationDetents([.large])
            }
            .trainTrackerBarTitleHidden(usesSplitLayout)
            .trainTrackerShowSidebarButton()
            .toolbar {
                if store.canEditSearch && !usesSplitLayout {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit Search", action: store.editSearch)
                        .accessibilityIdentifier("editJourneySearch")
                        .accessibilityHint("Returns to the journey form and keeps your search details")
                    }
                }
            }
            .navigationDestination(item: Binding(
                get: { navigation.requestedStationSearch },
                set: { if $0 == nil { navigation.dismissStationSearch() } }
            )) { request in
                StationSearchView(initialQuery: request.query)
                    // Each Siri or Shortcuts request is a fresh search, even while one is open.
                    .id(request.id)
                    .navigationTitle(JourneySearchCopy.Form.liveStationDepartures)
            }
    }

    /// Size class belongs to the window; the My Trips sidebar can leave this detail much
    /// narrower. Keep the form beside results only when both fit in the allocated column.
    private var usesSplitLayout: Bool {
        JourneySearchLayout.usesSplitLayout(
            availableWidth: availableWidth,
            isRegularWidth: horizontalSizeClass == .regular,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    /// Before there are results, use the canvas for the journey controls themselves instead
    /// of reserving an empty result pane. Fetched results retain their existing split layout.
    private var usesWideLanding: Bool {
        switch store.phase {
        case .editing, .completed, .failed(.outboundSearchUnavailable):
            JourneySearchLayout.usesTwoColumnForm(
                availableWidth: availableWidth,
                isRegularWidth: horizontalSizeClass == .regular,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )
        default:
            false
        }
    }

    private var splitContent: some View {
        HStack(spacing: 0) {
            searchLanding
                .frame(width: LayoutMetrics.sidePanelWidth)
            Divider()
                .ignoresSafeArea(.container, edges: .bottom)
            splitDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .trainTrackerPageBackground()
    }

    @ViewBuilder
    private var splitDetail: some View {
        switch store.phase {
        case .editing, .completed, .failed(.outboundSearchUnavailable):
            ContentUnavailableView {
                Label(JourneySearchCopy.Form.splitPlaceholderTitle, image: TrainTrackerSymbol.train)
            } description: {
                Text(JourneySearchCopy.Form.splitPlaceholderMessage)
            }
            .trainTrackerPageBackground()
        case .reviewing, .resolving, .failed(.resolutionUnavailable), .failed(.trackingTokenExpired):
            if store.selectedOutbound != nil {
                selectedJourneyDetail
            } else {
                ContentUnavailableView(
                    JourneySearchCopy.Form.splitPlaceholderTitle,
                    image: TrainTrackerSymbol.train
                )
                .trainTrackerPageBackground()
            }
        default:
            phaseContent
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch store.phase {
        case .editing, .failed(.outboundSearchUnavailable):
            searchLanding
        case .loadingOutbound:
            JourneySearchLoadingView(title: JourneySearchCopy.Form.findingOutbound)
        case .showingOutbound:
            outboundResults
        case .loadingReturn:
            JourneySearchLoadingView(
                title: JourneySearchCopy.Form.findingReturn,
                selectedOutbound: store.selectedOutbound
            )
        case .showingReturn:
            returnContent(searchUnavailable: false)
        case .failed(.returnSearchUnavailable):
            returnContent(searchUnavailable: true)
        case .reviewing, .resolving, .failed(.resolutionUnavailable), .failed(.trackingTokenExpired):
            selectedJourneyDetail
        case .completed:
            searchLanding
        }
    }

    private var searchLanding: some View {
        Form {
            // In the split the bar stays inline (result screens set their own inline titles), so
            // the column carries the title and it shares the form's leading edge.
            if usesSplitLayout {
                Section {
                } header: {
                    Text(JourneySearchCopy.search)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Color.ttTextPrimary)
                        .textCase(nil)
                        .accessibilityAddTraits(.isHeader)
                }
            }

            JourneySearchForm(
                store: store,
                presentedPicker: $presentedPicker,
                recentHistory: openedFromTicket || navigation.requestedTicketJourneySearch != nil ? nil : recents,
                usesTwoColumns: usesWideLanding
            )

            Section {
                NavigationLink {
                    StationSearchView()
                        .navigationTitle(JourneySearchCopy.Form.liveStationDepartures)
                } label: {
                    Label(JourneySearchCopy.Form.liveStationDepartures, systemImage: "clock.arrow.circlepath")
                }
            }
            .trainTrackerRowSurface()
        }
        .formStyle(.grouped)
        .listSectionSpacing(TrainTrackerSpacing.space16)
        .trainTrackerReadableWidth(
            usesWideLanding ? LayoutMetrics.desktopDetailMaxWidth : LayoutMetrics.readableFormWidth,
            minimumMargin: usesWideLanding ? LayoutMetrics.pageInset : 0
        )
        .trainTrackerPageBackground()
        .trainTrackerTabBarClearance()
    }

    @ViewBuilder
    private var outboundResults: some View {
        if let page = store.outboundPage {
            JourneyResultsView(
                direction: .outbound,
                context: JourneyResultsContext(direction: .outbound, form: store.form),
                page: page,
                options: store.visibleOutboundOptions,
                preferredTrainNumber: store.preferredTrainNumber,
                directOnly: store.form.directOnly,
                maximumTransfers: store.form.maximumTransfers,
                onDirectOnlyChanged: store.setDirectOnly,
                onMaximumTransfersChanged: {
                    store.rerunWithMaximumTransfers($0, direction: .outbound)
                },
                onSelect: store.selectOutbound,
                onLoadEarlier: store.loadEarlierOutbound,
                onLoadLater: store.loadLaterOutbound
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                if let message = store.importedReviewMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Color.ttTextSecondary)
                        .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
                        .padding(.horizontal, LayoutMetrics.pageInset)
                        .padding(.vertical, TrainTrackerSpacing.space12)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
        } else {
            JourneySearchLoadingView(title: JourneySearchCopy.Form.findingOutbound)
        }
    }

    @ViewBuilder
    private func returnContent(searchUnavailable: Bool) -> some View {
        if let outbound = store.selectedOutbound,
           searchUnavailable || store.earliestValidReturnTime != nil {
            JourneyReturnRecoveryView(
                outbound: outbound,
                earliestValidTime: store.earliestValidReturnTime,
                timeZoneIdentifier: store.form.returnTimeZoneIdentifier,
                searchUnavailable: searchUnavailable,
                editDestination: { JourneyReturnEditorView(store: store) },
                onUseEarliestTime: store.acceptAdjustedReturnSearch,
                onContinueOneWay: store.continueAsOneWay
            )
        } else if let page = store.returnPage, let outbound = store.selectedOutbound {
            switch JourneySearchPolicy.returnPageDisposition(page) {
            case .results:
                JourneyResultsView(
                    direction: .return,
                    context: JourneyResultsContext(direction: .return, form: store.form),
                    page: page,
                    options: store.visibleReturnOptions,
                    directOnly: store.form.directOnly,
                    maximumTransfers: store.form.maximumTransfers,
                    selectedOutbound: outbound,
                    onDirectOnlyChanged: store.setDirectOnly,
                    onMaximumTransfersChanged: {
                        store.rerunWithMaximumTransfers($0, direction: .return)
                    },
                    onSelect: store.selectReturn,
                    onLoadEarlier: store.loadEarlierReturn,
                    onLoadLater: store.loadLaterReturn
                )
            case .terminalRecovery:
                JourneyReturnRecoveryView(
                    outbound: outbound,
                    earliestValidTime: nil,
                    timeZoneIdentifier: store.form.returnTimeZoneIdentifier,
                    searchUnavailable: false,
                    editDestination: { JourneyReturnEditorView(store: store) },
                    onUseEarliestTime: store.acceptAdjustedReturnSearch,
                    onContinueOneWay: store.continueAsOneWay
                )
            }
        } else {
            JourneySearchLoadingView(
                title: JourneySearchCopy.Form.findingReturn,
                selectedOutbound: store.selectedOutbound
            )
        }
    }

    @ViewBuilder
    private var selectedJourneyDetail: some View {
        if store.selectedOutbound != nil {
            RoundTripReviewView(store: store)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if store.canChooseAnotherImportedTrain {
                        Button("Choose another train", action: store.chooseAnotherImportedTrain)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: LayoutMetrics.contentMaxWidth, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, LayoutMetrics.pageInset)
                            .frame(maxWidth: .infinity)
                            .background(.bar)
                            .accessibilityHint("Returns to the fetched departures without starting a new search")
                    }
                }
        } else {
            searchLanding
        }
    }

    private var navigationTitle: String {
        if usesSplitLayout { return JourneySearchCopy.search }
        return switch store.phase {
        case .loadingOutbound, .showingOutbound:
            JourneySearchCopy.Results.chooseOutbound
        case .loadingReturn, .showingReturn, .failed(.returnSearchUnavailable):
            JourneySearchCopy.Results.chooseReturn
        default:
            JourneySearchCopy.search
        }
    }
}

private struct JourneySearchLoadingView: View {
    let title: String
    var selectedOutbound: JourneyOption?

    var body: some View {
        VStack(spacing: LayoutMetrics.sectionSpacing) {
            if let selectedOutbound {
                JourneySelectedOutboundSummary(option: selectedOutbound)
            }
            ProgressView(title)
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: LayoutMetrics.contentMaxWidth)
        .padding(LayoutMetrics.pageInset)
        .frame(maxWidth: .infinity)
        .trainTrackerPageBackground()
    }
}

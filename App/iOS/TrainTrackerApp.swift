import SwiftUI
import TrainTrackerCore

@main
struct TrainTrackerApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @UIApplicationDelegateAdaptor(iOSAppDelegate.self) private var appDelegate
  @State private var account: AccountStore
  @State private var library: TripLibrary
  @State private var planLibrary: JourneyPlanLibrary?
  @State private var navigation: AppNavigationModel
  @State private var ticketInbox = TicketInbox()
  @State private var shareImport: ShareImportCoordinator
  @State private var ticketVault: LocalJourneyTicketStore
  @AppStorage(TrainTrackerPreference.appearance) private var appearance = AppearancePreference.system
  @State private var intake: JourneyIntakeModel
  @State private var forwarding = ForwardingStore()
  @State private var purchases: TicketPurchaseStore
  private let pushCoordinator: PushRegistrationCoordinator
  private let isStorePreview: Bool
  private let previewHorizontalSizeClass: UserInterfaceSizeClass?
  private let previewContentMaxWidth: CGFloat?
  private let previewReferenceDate: Date?
  #if DEBUG
    private let isStationBoardPreview: Bool
    private let isCalendarImportPreview: Bool
    private let isJourneyExperiencePreview: Bool
    private let isLiveActivityPreview: Bool
    private let isMapLegibilityPreview: Bool
    private let isTicketPurchasePreview: Bool
    private let isLineTicketComponentsPreview: Bool
    private let isWidgetPreview: Bool
  #endif

  /// Workflow QA can switch animations off for the whole app.
  private static let disablesWorkflowAnimations: Bool = {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      return FrictionlessIntakeQA.isEnabled(arguments: arguments) && arguments.contains("-WorkflowQANoAnimations")
    #else
      return false
    #endif
  }()

  init() {
    let pushCoordinator = TrainJourneyRuntime.shared.pushCoordinator
    let arguments = ProcessInfo.processInfo.arguments
    let journeyPlanPreview = JourneyPlanPreviewData.resolve(arguments: arguments)
    #if DEBUG
      let updateQA = TripUpdatesQA.libraries(arguments: arguments) ?? HudsonWindowQA.libraries(arguments: arguments)
        ?? PlatformBoardQA.libraries(arguments: arguments)
    #else
      let updateQA: (TripLibrary, JourneyPlanLibrary?)? = nil
    #endif
    let previewReferenceDate = journeyPlanPreview?.referenceDate
    self.previewReferenceDate = previewReferenceDate
    #if DEBUG
      let journeyExperiencePreview = arguments.contains("-JourneyExperiencePreview")
      let activityOrMapPreview = arguments.contains("-LiveActivityPreview") || arguments.contains("-MapLegibilityPreview")
        || arguments.contains("-TicketPurchasePreview") || arguments.contains("-TicketPurchasePreviewEntry")
        || arguments.contains("-TicketPurchasePreviewSaved") || arguments.contains("-WidgetPreview")
      let intakeQA = FrictionlessIntakeQA.isEnabled(arguments: arguments)
      if intakeQA && arguments.contains("-WorkflowQANoAnimations") {
        UIView.setAnimationsEnabled(false)
      }
      let accountRestorePreviewState: AccountStore.RestoreState? =
        if arguments.contains("-AccountRestorePreviewRestoring") {
          .pending
        } else if arguments.contains("-AccountRestorePreviewFailed") {
          .failed("The Internet connection appears to be offline.")
        } else {
          nil
        }
    #else
      let intakeQA = Self.isIntakeQA(arguments)
      let journeyExperiencePreview = false
      let activityOrMapPreview = false
      let accountRestorePreviewState: AccountStore.RestoreState? = nil
    #endif
    // No journeys at all, for checking the first-run screen.
    let firstRunPreview = arguments.contains { $0.hasPrefix("-FirstRunPreview") }
    let isStorePreview = arguments.contains("-AppStorePreview")
      || firstRunPreview
      || arguments.contains("-FirstRunLive")
      || journeyPlanPreview != nil
      || updateQA != nil
      || accountRestorePreviewState != nil
      || arguments.contains("-CalendarImportPreview")
      || journeyExperiencePreview
      || activityOrMapPreview
      || intakeQA
      || Self.amtrakPositionQATrip(arguments) != nil
    let navigation = TrainJourneyRuntime.shared.navigation
    #if DEBUG
      if JourneyResultsPreviewMode.resolve(arguments: arguments) != nil {
        navigation.open(.stations)
      }
    #endif
    self.pushCoordinator = pushCoordinator
    self.isStorePreview = isStorePreview
    #if DEBUG
      isStationBoardPreview = arguments.contains("-StationBoardPreview")
      isCalendarImportPreview = arguments.contains("-CalendarImportPreview")
      isJourneyExperiencePreview = journeyExperiencePreview
      isLiveActivityPreview = arguments.contains("-LiveActivityPreview")
      isMapLegibilityPreview = arguments.contains("-MapLegibilityPreview")
      isLineTicketComponentsPreview = arguments.contains("-LineTicketComponentsPreview")
      isWidgetPreview = arguments.contains("-WidgetPreview")
      isTicketPurchasePreview = arguments.contains("-TicketPurchasePreview") || arguments.contains("-TicketPurchasePreviewEntry") || arguments.contains("-TicketPurchasePreviewSaved")
      previewHorizontalSizeClass =
        JourneyPreviewHorizontalSizeClass
        .resolve(arguments: arguments)?
        .value
      previewContentMaxWidth =
        JourneyPreviewViewport
        .resolve(arguments: arguments)?
        .contentMaxWidth
    #else
      previewHorizontalSizeClass = nil
      previewContentMaxWidth = nil
    #endif
    let library: TripLibrary
    let planLibrary: JourneyPlanLibrary?
    if let journeyPlanPreview {
      let previewPush = JourneyPlanPreviewPushCoordinator()
      library = TripLibrary(
        trips: journeyPlanPreview.trips,
        pushCoordinator: previewPush,
        archive: nil,
        automaticRefreshEnabled: false,
        now: { previewReferenceDate ?? .now }
      )
      planLibrary = try? JourneyPlanLibrary(
        tripLibrary: library,
        archive: JourneyPlanPreviewArchive(plans: journeyPlanPreview.plans)
      )
      if journeyPlanPreview.showsPushWarning {
        let tripIDs = Set(journeyPlanPreview.trips.map(\.id))
        if arguments.contains("-JourneyPlanPreviewJourneySavePushWarning") {
          let scope = library.beginJourneySavePushScope(tripIDs: tripIDs)
          library.completeJourneySavePushScope(scope)
        }
        previewPush.showWarning(for: tripIDs)
      }
    } else if let updateQA {
      (library, planLibrary) = updateQA
    } else if let qaTrip = Self.amtrakPositionQATrip(arguments) {
      library = TripLibrary(
        trips: [qaTrip],
        backendSnapshots: Self.amtrakPositionQAData(qaTrip, arguments: arguments),
        pushCoordinator: JourneyPlanPreviewPushCoordinator(),
        archive: nil,
        // Refresh must run: it is the path that previously dropped Amtrak GPS.
        automaticRefreshEnabled: true
      )
      planLibrary = try? JourneyPlanLibrary(tripLibrary: library, archive: JourneyPlanPreviewArchive(plans: []))
    } else if arguments.contains("-FirstRunLive") {
      // Nothing saved and nothing written, but the real service: the first-run screen as a new
      // rider meets it.
      library = TripLibrary(trips: [], pushCoordinator: JourneyPlanPreviewPushCoordinator(), archive: nil, automaticRefreshEnabled: true)
      planLibrary = try? JourneyPlanLibrary(tripLibrary: library, archive: JourneyPlanPreviewArchive(plans: []))
    } else if intakeQA || firstRunPreview {
      library = TripLibrary(
        trips: [],
        pushCoordinator: JourneyPlanPreviewPushCoordinator(),
        archive: nil,
        automaticRefreshEnabled: false
      )
      planLibrary = try? JourneyPlanLibrary(
        tripLibrary: library,
        archive: JourneyPlanPreviewArchive(plans: [])
      )
    } else {
      if isStorePreview {
        library = TripLibrary.preview(pushCoordinator: pushCoordinator)
        planLibrary = try? JourneyPlanLibrary(tripLibrary: library)
      } else {
        library = TrainJourneyRuntime.shared.library
        planLibrary = TrainJourneyRuntime.shared.planLibrary
        TrainJourneyRuntime.shared.ensureActivityConnection()
      }
    }
    // Intake QA launches signed out, so account-only services never run against a fake session.
    _account = State(initialValue: AccountStore(
      preview: isStorePreview && accountRestorePreviewState == nil && !intakeQA,
      restoreState: intakeQA ? .restored : accountRestorePreviewState
    ))
    // Journeys saved before this launch already have their tickets; only new ones print.
    TicketPrintQueue.shared.seed(library.trips.map(\.id.rawValue))
    _library = State(initialValue: library)
    _planLibrary = State(initialValue: planLibrary)
    _navigation = State(initialValue: navigation)
    var purchaseFileURL: URL? = isStorePreview ? nil : TicketPurchaseStore.defaultURL
    #if DEBUG
      if isTicketPurchasePreview, arguments.contains("-TicketPurchasePreviewPersistent") {
        purchaseFileURL = URL.applicationSupportDirectory.appending(path: "TicketPurchaseQA/searches.json")
        if arguments.contains("-TicketPurchasePreviewReset"), let purchaseFileURL {
          try? FileManager.default.removeItem(at: purchaseFileURL)
        }
      }
    #endif
    _purchases = State(initialValue: TicketPurchaseStore(fileURL: purchaseFileURL))

    // Previews and QA keep tickets in an isolated temporary directory, never the saved vault.
    var vaultDirectory: URL? = isStorePreview
      ? URL.temporaryDirectory.appending(path: "PreviewJourneyTickets", directoryHint: .isDirectory)
      : nil
    var makeClient: @MainActor () -> any JourneySearching = { JourneySearchClient() }
    #if DEBUG
      if arguments.contains("-MyTripsPastOnlyQA") || arguments.contains("-MyTripsPastPlansQA") || arguments.contains(PlatformBoardQA.flag) {
        // Each home-history scenario starts without reviews left by another QA launch.
        vaultDirectory = URL.temporaryDirectory.appending(
          path: "MyTripsHistoryQA/\(UUID().uuidString)", directoryHint: .isDirectory
        )
      }
      if arguments.contains("-MyTripsTicketHistoryPreview") {
        vaultDirectory = URL.temporaryDirectory.appending(path: "TicketHistoryPreview", directoryHint: .isDirectory)
      }
      if intakeQA {
        vaultDirectory = FrictionlessIntakeQA.vaultDirectory(arguments: arguments)
        let qaClient = FrictionlessIntakeQAClient(failuresBeforeSuccess: FrictionlessIntakeQA.searchFailures(arguments: arguments))
        makeClient = { qaClient }
      }
    #endif
    let vault = LocalJourneyTicketStore(directory: vaultDirectory)
    #if DEBUG
      if arguments.contains(PlatformBoardQA.flag) {
        Task { try? await PlatformBoardQA.seedTicket(in: vault) }
      }
      if arguments.contains("-MyTripsTicketHistoryPreview"), vault.reviews.isEmpty {
        try? vault.saveDraft(TicketRouteSuggestion(
          id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
          sourceDescription: "Shared ticket", subtitle: "Train confirmation",
          originGuess: "Aéroport Paris Roissy Charles de Gaulle CDG T2", destinationGuess: "Avignon TGV"
        ))
      }
    #endif
    let intake = JourneyIntakeModel(vault: vault, makeClient: makeClient)
    _ticketVault = State(initialValue: vault)
    _intake = State(initialValue: intake)
    // A shared ticket is saved locally before its App Group staging copy is acknowledged.
    _shareImport = State(initialValue: ShareImportCoordinator(handoff: { manifest, payload, parsed in
      let result = try await vault.importPayload(
        payload, kind: manifest.kind, filename: manifest.suggestedFilename, parsed: parsed
      )
      intake.sharedTicketSaved(result.ticket)
    }))
  }

  var body: some Scene {
    WindowGroup {
      previewLayout(
        Group {
          if let planLibrary {
            Group {
              #if DEBUG
                if isLineTicketComponentsPreview {
                  LineTicketComponentsPreviewScene()
                } else if isWidgetPreview {
                  WidgetPreviewScene()
                } else if isTicketPurchasePreview {
                  TicketPurchasePreviewScene(planLibrary: planLibrary,
                    entry: ProcessInfo.processInfo.arguments.contains("-TicketPurchasePreviewEntry"))
                } else if isLiveActivityPreview {
                  LiveActivityPreviewScene()
                } else if isMapLegibilityPreview {
                  MapLegibilityPreviewScene()
                } else if isJourneyExperiencePreview {
                  JourneyExperiencePreviewScene()
                } else if isCalendarImportPreview {
                  CalendarImportPreviewView()
                } else if isStationBoardPreview {
                  NavigationStack {
                    StationSearchView(initialSelection: StationSearchView.berlinPreviewMatch)
                      .navigationTitle("Track a Train")
                  }
                } else {
                  AppRootView(indexesSavedTrains: !isStorePreview)
                }
              #else
                AppRootView(indexesSavedTrains: !isStorePreview)
              #endif
            }
              .environment(account)
              .environment(library)
              .environment(planLibrary)
              .environment(navigation)
              .environment(ticketInbox)
              .environment(shareImport)
              .environment(ticketVault)
              .environment(intake)
              .environment(forwarding)
              .environment(purchases)
              .environment(\.journeyReferenceDate, previewReferenceDate)
              // Settings › Appearance. Automatic follows the system.
              .preferredColorScheme(appearance.colorScheme)
              // SwiftUI can call a transaction closure off the main actor while it renders an
              // animation asynchronously. An isolated closure traps there, so this one is
              // @Sendable and captures a flag read up front.
              .transaction { @Sendable [disablesAnimations = Self.disablesWorkflowAnimations] transaction in
                if disablesAnimations { transaction.disablesAnimations = true }
              }
              .task {
                guard !isStorePreview else { return }
                RoundhouseTipStore.shared.startObserving()
                await TripDeliveredAlert.readDelivered(into: library)
                pushCoordinator.connect()
                library.resumePushWatches()
                await account.restore()
                if ReleaseFeatures.gmailImportEnabled, account.currentUser != nil {
                  await ticketInbox.restore()
                }
                if let userID = account.currentUser?.id {
                  await forwarding.signedIn(userID: userID)
                }
              }
              .onChange(of: scenePhase) { _, phase in
                if phase == .active, !isStorePreview {
                  Task { await TripDeliveredAlert.readDelivered(into: library) }
                }
              }
          } else {
            ContentUnavailableView(
              JourneySearchCopy.Plan.savedUnavailable,
              systemImage: "exclamationmark.triangle",
              description: Text(JourneySearchCopy.Plan.savedUnavailableDescription)
            )
          }
        })
    }
  }

  private static func amtrakPositionQATrip(_ arguments: [String]) -> TrainTrip? {
    #if DEBUG
      AmtrakPositionQA.isEnabled(arguments: arguments) ? AmtrakPositionQA.trip() : nil
    #else
      nil
    #endif
  }

  private static func amtrakPositionQAData(_ trip: TrainTrip, arguments: [String]) -> any TripDataProviding {
    #if DEBUG
      AmtrakPositionQASnapshots(template: trip, includesPosition: AmtrakPositionQA.includesPosition(arguments: arguments))
    #else
      TripSnapshotBackendClient()
    #endif
  }

  /// Intake QA is a DEBUG-only fixture; release builds never enable it.
  private static func isIntakeQA(_ arguments: [String]) -> Bool {
    #if DEBUG
      FrictionlessIntakeQA.isEnabled(arguments: arguments)
    #else
      false
    #endif
  }

  @ViewBuilder
  private func previewLayout<Content: View>(_ content: Content) -> some View {
    #if DEBUG
      if let previewHorizontalSizeClass, let previewContentMaxWidth {
        content
          .environment(\.horizontalSizeClass, previewHorizontalSizeClass)
          .frame(maxWidth: previewContentMaxWidth)
      } else {
        content
      }
    #else
      content
    #endif
  }
}

import SwiftUI
import TrainTrackerCore

struct AppRootView: View {
  @Environment(AccountStore.self) private var account
  @Environment(TripLibrary.self) private var library
  @Environment(JourneyPlanLibrary.self) private var planLibrary
  @Environment(LocalJourneyTicketStore.self) private var ticketVault
  @Environment(TicketInbox.self) private var ticketInbox
  @Environment(ShareImportCoordinator.self) private var shareImport
  @Environment(JourneyIntakeModel.self) private var intake
  @Environment(ForwardingStore.self) private var forwarding
  @Environment(AppNavigationModel.self) private var navigation
  @Environment(\.scenePhase) private var scenePhase
  let indexesSavedTrains: Bool

  init(indexesSavedTrains: Bool = true) {
    self.indexesSavedTrains = indexesSavedTrains
  }

  var body: some View {
    MobileRootView()
    .tint(Color.ttActionTint)
    .onOpenURL { url in
      Task {
        if url.scheme == "traintracker", url.host() == "add-journey" {
          // The empty Next Train widget: open My Trips with Add Journey, as the toolbar does.
          navigation.open(.trips)
          intake.presentAddJourney()
        } else if url.scheme == "traintracker", url.host() == "next-train" {
          // The Next Train control: the train the widget would show, or Add Journey when none.
          openNextTrain()
        } else if navigation.openJourneyURL(url) {
          return
        } else if await account.handleCallback(url) {
          return
        } else if ReleaseFeatures.gmailImportEnabled, TicketInbox.isCallback(url) {
          await ticketInbox.handleCallback(url)
        } else if ShareImportCoordinator.isCallback(url) {
          await shareImport.handleCallback(url)
        } else {
          await library.importSharedTrip(from: url)
        }
      }
    }
    .onChange(of: account.currentUser?.id) { _, userID in
      Task {
        await ticketInbox.reset()
        if ReleaseFeatures.gmailImportEnabled, userID != nil {
          await ticketInbox.restore()
        }
        if let userID {
          await forwarding.signedIn(userID: userID)
        } else {
          forwarding.signedOut()
        }
      }
    }
    .onAppear {
      Task { await shareImport.scanForPendingShares() }
    }
    .task {
      try? library.retryTripArchiveRecovery()
      try? planLibrary.retryRecovery()
      await TrainLiveActivityManager.shared.resume()
      // Opening the app puts a train that is underway or about to leave on the Lock Screen.
      LockScreenAutoStart.startIfDue(library: library, plans: planLibrary)
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(20)) }
        catch { return }
        if scenePhase == .active {
          await TrainLiveActivityManager.shared.resume()
          LockScreenAutoStart.startIfDue(library: library, plans: planLibrary)
        }
      }
    }
    .task(id: savedTrainIndexEntities) {
      guard indexesSavedTrains else { return }
      await SavedTrainSpotlightIndexer.synchronize(savedTrainIndexEntities)
    }
    .onChange(of: library.trips.map(\.id)) { _, _ in
      TrainJourneyShortcuts.updateAppShortcutParameters()
    }
    .onChange(of: ticketLinkState, initial: true) { _, _ in
      guard planLibrary.recoveryIssues.isEmpty, !library.tripArchiveRecoveryRequired,
            ticketVault.isAvailable else { return }
      do {
        try ticketVault.reconcileLinks(
          planIDs: Set(planLibrary.plans.map(\.id)),
          tripIDs: Set(library.trips.map { $0.id.rawValue })
        )
      } catch {
        intake.report(error.localizedDescription)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
      try? library.retryTripArchiveRecovery()
      try? planLibrary.retryRecovery()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        Task {
          try? library.retryTripArchiveRecovery()
          try? planLibrary.retryRecovery()
          await TrainLiveActivityManager.shared.resume()
          LockScreenAutoStart.startIfDue(library: library, plans: planLibrary)
          await shareImport.scanForPendingShares()
          if let userID = account.currentUser?.id {
            await forwarding.signedIn(userID: userID)
          }
        }
      }
    }
    .sheet(item: Binding(
      get: { intake.presentation },
      set: { if $0 == nil { intake.dismissPresentation() } }
    )) { presentation in
      switch presentation {
      case let .addJourney(owner):
        AddJourneyView(attachTo: owner)
            .tint(Color.ttActionTint)
      case let .review(request):
        reviewSheet(request)
      }
    }
    .alert(
      "Add Journey",
      isPresented: Binding(
        get: { intake.errorMessage != nil && intake.presentation == nil && !intake.hasLocalPresentation },
        set: { if !$0 { intake.dismissError() } }
      )
    ) {
      Button("OK") { intake.dismissError() }
    } message: {
      Text(intake.errorMessage ?? "")
    }
    .alert(
      "Shared Item",
      isPresented: Binding(
        get: {
          shareImport.pendingReview == nil && shareImport.errorMessage != nil
            && intake.presentation == nil && !intake.hasLocalPresentation
        },
        set: { if !$0 { Task { await shareImport.dismissError() } } }
      )
    ) {
      Button("OK") { Task { await shareImport.dismissError() } }
    } message: {
      Text(shareImport.errorMessage ?? "")
    }
  }

  private func openNextTrain() {
    let snapshot = WidgetSnapshotPublisher.snapshot(
      trips: library.trips, plans: planLibrary.plans, at: .now,
      lastSuccessfulCheck: { library.lastSuccessfulCheck(for: $0) },
      lastRefreshFailed: { library.lastRefreshFailed(for: $0) }
    )
    if let link = WidgetDisplay(snapshot: snapshot, at: .now).primary?.deepLinkURL, navigation.openJourneyURL(link) {
      return
    }
    navigation.open(.trips)
    intake.presentAddJourney()
  }

  private func reviewSheet(_ request: JourneyIntakeModel.ReviewRequest) -> some View {
    NavigationStack {
      SmartJourneyReviewView(
        suggestion: request.suggestion,
        ticketDetails: request.ticketDetails,
        linkedPlanIDs: request.linkedPlanIDs,
        planLibrary: planLibrary,
        makeClient: intake.makeClient,
        onDraftChange: { intake.saveDraft($0) },
        onSaved: { plan, created in
          intake.completeReview(request, plan: plan, created: created, navigation: navigation)
        },
        onOpenExisting: { plan in
          intake.openExisting(request, plan: plan, navigation: navigation)
        },
        onClose: { intake.dismissPresentation() }
      )
    }
    .alert(
      "Add Journey",
      isPresented: Binding(
        get: { intake.errorMessage != nil },
        set: { if !$0 { intake.dismissError() } }
      )
    ) {
      Button("OK") { intake.dismissError() }
    } message: {
      Text(intake.errorMessage ?? "")
    }
  }

  private var savedTrainIndexEntities: [SavedTrainEntity] {
    SavedTrainEntityCatalog(trips: library.trips, plans: planLibrary.plans).allEntities()
  }

  private var ticketLinkState: TicketLinkState {
    TicketLinkState(planIDs: Set(planLibrary.plans.map(\.id)),
      tripIDs: Set(library.trips.map { $0.id.rawValue }),
      archivesHealthy: planLibrary.recoveryIssues.isEmpty && !library.tripArchiveRecoveryRequired,
      ticketsAvailable: ticketVault.isAvailable)
  }

  private struct TicketLinkState: Equatable {
    let planIDs: Set<UUID>
    let tripIDs: Set<String>
    let archivesHealthy: Bool
    let ticketsAvailable: Bool
  }
}

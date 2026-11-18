import ActivityKit
import AppIntents
import SwiftUI
import TrainTrackerCore
import UIKit
import WidgetKit
import UniformTypeIdentifiers
import UserNotifications

struct TrainTrackerSettingsView: View {
  @Environment(AccountStore.self) private var account
  @Environment(TripLibrary.self) private var library
  @Environment(JourneyPlanLibrary.self) private var planLibrary
  @Environment(LocalJourneyTicketStore.self) private var ticketVault
  @AppStorage(TrainTrackerPreference.appearance) private var appearance = AppearancePreference.system
  @AppStorage(TrainTrackerPreference.background) private var background = BackgroundPreference.standard
  @AppStorage(TrainTrackerPreference.statusTintsBackground) private var statusTintsBackground = true
  @AppStorage(TrainTrackerPreference.ticketTexture) private var ticketTexture = true
  @AppStorage(TrainTrackerPreference.liveHaptics) private var liveHaptics = true
  @AppStorage(TrainTrackerPreference.mapStyle) private var mapStyle = MapStylePreference.muted
  @AppStorage(TrainTrackerPreference.whiteTexture) private var whiteTexture = WhiteTexturePreference.halftone
  @AppStorage(TimeFormatPreference.key, store: TimeFormatPreference.sharedDefaults)
  private var timeFormat = TimeFormatPreference.system
  @State private var homeStation = HomeStationStore.standard
  @State private var homePickerStore: JourneySearchStore?
  @State private var recents = RailPlaceRecents.standard
  @State private var liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
  @State private var confirmsPersonalizationReset = false
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .body) private var minimumColumnWidth: CGFloat = 320
  @State private var confirmsAccountDeletion = false
  @State private var notificationAccess = TrainTrackerNotificationAccess.checking
  @State private var presentsSignIn = false
  @State private var presentsRecoveryExport = false
  @State private var presentsRecoveryReset = false
  @State private var recoveryDocument = JourneyPlanRecoveryDocument()
  @State private var recoveryExportFilename = "TrainTracker-Journey-Recovery.bin"
  @State private var recoveryResetComponent: JourneyPlanStorageComponent?
  @State private var recoveryErrorMessage: String?
  @State private var presentsTripArchiveReset = false
  @State private var accountDeletionError: String?

  private var usesColumnTitle: Bool { horizontalSizeClass == .regular }

  private var deviceName: String { TrainTrackerDeviceName.current }

  var body: some View {
    // Read the navigation viewport, never the columns' fixed width. A fold can shrink the
    // viewport below that previous width, and the child must not keep its own breakpoint alive.
    GeometryReader { proxy in
      let layout = SettingsLayoutGeometry(
        space: JourneyPanelGeometry(proxy), minimumColumnWidth: minimumColumnWidth,
        usesAccessibilityType: dynamicTypeSize.isAccessibilitySize
      )
      Group {
        if let columns = layout.columns {
          gridLayout(columns)
        } else {
          singleColumn
            .frame(width: layout.singleColumnWidth)
            .frame(maxWidth: .infinity, alignment: layout.singleColumnAlignment)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .trainTrackerBarTitleHidden(usesColumnTitle || layout.columns != nil)
      .toolbarBackground(layout.columns != nil ? .hidden : .automatic, for: .navigationBar)
    }
    .trainTrackerPageBackground()
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .confirmationDialog(
      "Delete your Roundhouse account?",
      isPresented: $confirmsAccountDeletion,
      titleVisibility: .visible
    ) {
      Button("Delete Account", role: .destructive) {
        Task {
          // Deletion failures are shown here; the sign-in sheet never inherits them.
          if await !account.deleteAccount() {
            accountDeletionError = account.errorMessage ?? "Your account couldn't be deleted. Try again."
            account.dismissError()
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Your server-side account data will be deleted. Trips saved on this \(deviceName) remain. This cannot be undone.")
    }
    .confirmationDialog(
      recoveryResetComponent.map { "Reset \($0.resetTitle)?" } ?? "Reset recovery data?",
      isPresented: $presentsRecoveryReset,
      titleVisibility: .visible
    ) {
      if let component = recoveryResetComponent {
        Button("Reset \(component.resetTitle)", role: .destructive) {
          resetJourneyPlanRecovery(component)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      if let component = recoveryResetComponent {
        Text(component.resetConfirmationMessage)
      }
    }
    .confirmationDialog(
      "Reset saved trains?",
      isPresented: $presentsTripArchiveReset,
      titleVisibility: .visible
    ) {
      Button("Reset Saved Trains", role: .destructive) {
        resetTripArchiveRecovery()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently removes the unreadable saved-train archive and its recovery copy from this \(deviceName). Export the recovery data first if you may need it later. Journey Plans and imported tickets remain.")
    }
    .fileExporter(
      isPresented: $presentsRecoveryExport,
      document: recoveryDocument,
      contentType: .data,
      defaultFilename: recoveryExportFilename
    ) { result in
      if case let .failure(error) = result {
        recoveryErrorMessage = error.localizedDescription
      }
    }
    .alert(
      "Storage Recovery",
      isPresented: Binding(
        get: { recoveryErrorMessage != nil },
        set: { if !$0 { recoveryErrorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(recoveryErrorMessage ?? "The recovery action couldn't be completed.")
    }
    .alert(
      "Account Not Deleted",
      isPresented: Binding(
        get: { accountDeletionError != nil },
        set: { if !$0 { accountDeletionError = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(accountDeletionError ?? "")
    }
    .sheet(isPresented: $presentsSignIn) {
      AccountGateView()
    }
    .confirmationDialog(
      "Reset personalization?",
      isPresented: $confirmsPersonalizationReset,
      titleVisibility: .visible
    ) {
      Button("Reset to Defaults", role: .destructive) {
        withAnimation(.smooth) {
          TrainTrackerPreference.resetAll()
          timeFormat = .system
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Appearance, background, ticket, haptics, map and time format go back to how Roundhouse ships. Your trips, tickets, alerts, home station and account are not affected.")
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
      await refreshNotificationAccess()
    }
  }


  private var singleColumn: some View {
    Form {
      travellerSection(showsTitle: usesColumnTitle)
      recoverySections
      travelLogSection
      TrainAlertSettingsSection()
      personalizationSection
      timesAndPlacesSection
      shortcutsSection
      accountSection
      TrainTrackerDataAndCoverageSection()
      deviceDataSection
      supportSection
      accountDataSection
    }
    .formStyle(.grouped)
    .labelStyle(SettingsTileLabelStyle())
    .contentMargins(.top, TrainTrackerSpacing.space8, for: .scrollContent)
    .trainTrackerReadableWidth()
    .trainTrackerTabBarClearance()
  }

  private func gridLayout(_ columns: SettingsLayoutGeometry.Columns) -> some View {
    SettingsColumnsLayout(columns: columns) {
      Form {
        travellerSection(showsTitle: true)
        recoverySections
        travelLogSection
        accountSection
        TrainTrackerDataAndCoverageSection()
        accountDataSection
      }
    } preferences: {
      Form {
        TrainAlertSettingsSection()
        personalizationSection
        timesAndPlacesSection
        shortcutsSection
        deviceDataSection
        supportSection
      }
    }
  }

  private var readiness: TrainTrackerSettingsReadiness {
    TrainTrackerSettingsReadiness(
      savedTripCount: library.trips.count,
      notificationAccess: notificationAccess,
      tripArchiveRecoveryRequired: library.tripArchiveRecoveryRequired,
      deviceName: deviceName
    )
  }

  /// The account ticket and the two things iOS decides for the app, ahead of everything else.
  @ViewBuilder
  private func travellerSection(showsTitle: Bool) -> some View {
    // The ticket and tiles sit in the section header: a list row would clip the ticket's shadow
    // at its edges and leave a slab of it inside the notches.
    Section {
    } header: {
      VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
        // The title scrolls with the traveler pass. It never reserves a shared heading band
        // above the independently scrolling preferences column.
        if showsTitle {
          Text("Settings")
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(Color.ttTextPrimary)
            .accessibilityAddTraits(.isHeader)
        }

        if account.currentUser == nil, !account.isRestoring {
          Button {
            presentsSignIn = true
          } label: {
            passCard
          }
          .buttonStyle(.plain)
          .accessibilityHint("Opens sign in")
        } else {
          passCard
        }

        HStack(alignment: .top, spacing: TrainTrackerSpacing.space12) {
          SettingsStatusTile(
            systemImage: notificationAccess.systemImage,
            title: "Alerts",
            value: notificationAccess.title,
            tint: notificationAccess.tint,
            hint: "Opens notification settings for Roundhouse",
            action: openNotificationSettings
          )
          SettingsStatusTile(
            systemImage: liveActivitiesEnabled ? "platter.filled.top.iphone" : "iphone.slash",
            title: "Live Activities",
            value: liveActivitiesEnabled ? "On" : "Off",
            tint: liveActivitiesEnabled ? .ttStatusOnTime : .ttStatusDelayed,
            hint: "Opens Roundhouse in the Settings app",
            action: openAppSettings
          )
        }
        // Room for the ticket's drop shadow above the tiles.
        .padding(.top, TrainTrackerSpacing.space12)

        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
          Text(readiness.title)
            .font(.subheadline.weight(.semibold))
          Text(readiness.detail)
            .font(.footnote)
        }
        .foregroundStyle(Color.ttTextPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, TrainTrackerSpacing.space4)
      }
      .textCase(nil)
      .listRowInsets(EdgeInsets())
    }
  }

  private var passCard: some View {
    SettingsPassCard(
      name: account.currentUser?.preferredName ?? "Guest",
      caption: passCaption,
      stamp: account.currentUser == nil ? "Guest" : "Signed in",
      fields: passFields,
      seed: account.currentUser?.id ?? deviceName
    )
  }

  private var passCaption: String {
    if account.isRestoring { return "Restoring your account…" }
    guard let user = account.currentUser else { return "Trips are saved on this \(deviceName)" }
    return user.email ?? "Signed in with \(user.providers.map(\.displayName).joined(separator: ", "))"
  }

  private var passFields: [TicketStubField] {
    [
      TicketStubField(
        id: "trains", label: "Trains",
        value: library.tripArchiveRecoveryRequired ? TicketStubField.unavailableValue : "\(library.trips.count)",
        usesNumericDigits: true
      ),
      TicketStubField(id: "journeys", label: "Journeys", value: "\(planLibrary.plans.count)", usesNumericDigits: true),
      TicketStubField(id: "tickets", label: "Tickets", value: "\(ticketVault.tickets.count)", usesNumericDigits: true),
    ]
  }

  private var personalizationSection: some View {
    Section {
      VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
        Label("Appearance", systemImage: "circle.lefthalf.filled")
        Picker("Appearance", selection: $appearance) {
          ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      .padding(.vertical, TrainTrackerSpacing.space4)

      Picker(selection: $background) {
        ForEach(BackgroundPreference.allCases) { Text($0.title).tag($0) }
      } label: {
        Label("Background", systemImage: "water.waves")
          .labelStyle(SettingsTileLabelStyle())
      }

      if background == .white {
        Picker(selection: $whiteTexture) {
          ForEach(WhiteTexturePreference.allCases) { Text($0.title).tag($0) }
        } label: {
          Label("Page Texture", systemImage: "circle.dotted")
            .labelStyle(SettingsTileLabelStyle())
        }
      }

      Toggle(isOn: $statusTintsBackground) {
        Label {
          SettingsRowTitle(
            title: "Color Follows Your Trip",
            detail: "The page warms when a tracked train is late or canceled."
          )
        } icon: {
          Image(systemName: "paintpalette")
        }
        .labelStyle(SettingsTileLabelStyle())
      }
      .disabled(!background.takesStatusTint)

      Toggle(isOn: $ticketTexture) {
        Label {
          SettingsRowTitle(title: "Printed Tickets", detail: "Halftone grain and engraved lines on live tickets.")
        } icon: {
          Image(systemName: "ticket")
        }
        .labelStyle(SettingsTileLabelStyle())
      }

      Toggle(isOn: $liveHaptics) {
        Label {
          SettingsRowTitle(title: "Haptics", detail: "A tap when a live time, platform or status changes.")
        } icon: {
          Image(systemName: "hand.tap")
        }
        .labelStyle(SettingsTileLabelStyle())
      }
    } header: {
      Text("Make It Yours")
    } footer: {
      Text("Reduce Motion, Increase Contrast and Low Power Mode still take priority over these choices.")
        .foregroundStyle(Color.ttTextPrimary)
    }
    .tint(Color.ttActionTint)
    .trainTrackerRowSurface()
  }

  private var timesAndPlacesSection: some View {
    Section {
      Picker(selection: $timeFormat) {
        ForEach(TimeFormatPreference.allCases) { Text($0.title).tag($0) }
      } label: {
        Label("Time Format", systemImage: "clock")
          .labelStyle(SettingsTileLabelStyle())
      }
      .onChange(of: timeFormat) { WidgetCenter.shared.reloadAllTimelines() }

      Button {
        homePickerStore = JourneySearchStore(client: JourneySearchClient(), planTracker: planLibrary)
      } label: {
        LabeledContent {
          Text(homeStation.place?.displayName ?? "Not Set")
            .foregroundStyle(Color.ttTextSecondary)
        } label: {
          Label {
            SettingsRowTitle(title: "Home Station", detail: "Journey search starts from here.")
          } icon: {
            Image(systemName: "house")
          }
          .labelStyle(SettingsTileLabelStyle())
        }
      }
      .swipeActions {
        if homeStation.place != nil {
          Button("Remove", role: .destructive) { homeStation.clear() }
        }
      }
      .sheet(isPresented: Binding(
        get: { homePickerStore != nil },
        set: { if !$0 { homePickerStore = nil } }
      )) {
        if let store = homePickerStore {
          RailPlacePicker(
            role: .origin, store: store, recents: recents,
            title: "Home Station", onSelect: { homeStation.set($0) }
          )
          .presentationDetents([.large])
        }
      }

      if homeStation.place != nil {
        Button(role: .destructive) {
          withAnimation(.smooth) { homeStation.clear() }
        } label: {
          Label("Remove Home Station", systemImage: "house.slash")
            .labelStyle(SettingsTileLabelStyle())
        }
      }

      Picker(selection: $mapStyle) {
        ForEach(MapStylePreference.allCases) { Text($0.title).tag($0) }
      } label: {
        Label("Map Style", systemImage: "map")
          .labelStyle(SettingsTileLabelStyle())
      }
    } header: {
      Text("Times & Places")
    } footer: {
      Text("Automatic follows this \(deviceName)'s 12- or 24-hour setting. Station times stay in the station's own time zone.")
        .foregroundStyle(Color.ttTextPrimary)
    }
    .tint(Color.ttActionTint)
    .trainTrackerRowSurface()
  }

  private var travelLogSection: some View {
    Section {
      NavigationLink(value: TripsRoute.travelLog) {
        Label {
          SettingsRowTitle(title: "Travel Log", detail: travelLogDetail)
        } icon: {
          Image(systemName: "ticket")
        }
        .labelStyle(SettingsTileLabelStyle())
      }
      .accessibilityIdentifier("travelLogFromSettings")
    }
    .trainTrackerRowSurface()
  }

  private var travelLogDetail: String {
    let totals = TravelLog.shared.totals
    guard totals.journeys > 0 else { return "Finished journeys are kept here as ticket stubs." }
    let journeys = totals.journeys == 1 ? "1 journey" : "\(totals.journeys) journeys"
    return "\(journeys) · \(TravelLogFormat.distance(totals.distanceMeters)) · \(TravelLogFormat.duration(totals.duration))"
  }

  private var shortcutsSection: some View {
    Section {
      VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
        Label {
          SettingsRowTitle(
            title: "Siri & Shortcuts",
            detail: "Ask for a saved train's status, or add it to a shortcut."
          )
        } icon: {
          Image(systemName: "mic")
        }
        ShortcutsLink()
          .shortcutsLinkStyle(.automaticOutline)
      }
      .padding(.vertical, TrainTrackerSpacing.space4)
    }
    .trainTrackerRowSurface()
  }

  /// What Train Tracker keeps on this device beyond trips, and the way back to defaults.
  private var deviceDataSection: some View {
    Section {
      Button {
        withAnimation(.smooth) { recents.clear() }
      } label: {
        LabeledContent {
          Text(recents.count == 0 ? "None" : "\(recents.count)")
            .foregroundStyle(Color.ttTextSecondary)
        } label: {
          Label("Clear Recent Searches", systemImage: "clock.arrow.circlepath")
            .labelStyle(SettingsTileLabelStyle())
        }
      }
      .disabled(recents.count == 0)

      Button {
        confirmsPersonalizationReset = true
      } label: {
        Label("Reset Personalization", systemImage: "arrow.counterclockwise")
      }
    } header: {
      Text("On This \(deviceName)")
    }
    .trainTrackerRowSurface()
  }

  @ViewBuilder
  private var recoverySections: some View {
    if library.tripArchiveRecoveryRequired {
      Section {
        Text(library.tripArchiveTemporarilyUnavailable
          ? "Saved trains are temporarily unavailable. Unlock the device and try reading again."
          : "Roundhouse can't read your saved trains. The original data is preserved, and changes to tracked trains are paused.")
          .font(.subheadline)
          .foregroundStyle(Color.ttTextSecondary)

        Button {
          retryTripArchiveRecovery()
        } label: {
          Label("Try Reading Again", systemImage: "arrow.clockwise")
        }

        Button {
          exportTripArchiveRecovery()
        } label: {
          Label("Export Recovery Data", systemImage: "square.and.arrow.up")
        }

        Button(role: .destructive) {
          presentsTripArchiveReset = true
        } label: {
          Label("Reset Saved Trains", systemImage: "trash")
        }
        .disabled(library.tripArchiveTemporarilyUnavailable)
      } header: {
        Text("Saved Train Recovery")
      } footer: {
        Text("Export the preserved data before resetting if you may need it later. Reset only clears unreadable saved trains; journey plans and imported tickets remain.")
          .foregroundStyle(Color.ttTextPrimary)
      }
      .trainTrackerRowSurface()
    }

    if !planLibrary.recoveryIssues.isEmpty {
      Section {
        ForEach(planLibrary.recoveryIssues) { issue in
          VStack(alignment: .leading, spacing: 10) {
            Label(issue.component.title, systemImage: "externaldrive.badge.exclamationmark")
              .font(.headline)
              .foregroundStyle(Color.ttStatusDelayed)

            Text(issue.recoveryDescription)
              .font(.subheadline)
              .foregroundStyle(Color.ttTextSecondary)

            Button {
              retryJourneyPlanRecovery(issue.component)
            } label: {
              Label("Try Reading Again", systemImage: "arrow.clockwise")
            }

            Button {
              exportJourneyPlanRecovery(issue.component)
            } label: {
              Label("Export Recovery Data", systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive) {
              recoveryResetComponent = issue.component
              presentsRecoveryReset = true
            } label: {
              Label("Reset \(issue.component.resetTitle)", systemImage: "trash")
            }
            .disabled(issue.failure == .storageUnavailable)
          }
          .padding(.vertical, 4)
        }
      } header: {
        Text("Journey Plan Recovery")
      } footer: {
        Text("Your saved trains remain available. Recovery data stays on this \(deviceName) unless you confirm a reset.")
          .foregroundStyle(Color.ttTextPrimary)
      }
      .trainTrackerRowSurface()
    }
  }

  private var accountSection: some View {
    Section("Account & Sync") {
      if account.isRestoring {
        Label("Restoring your account…", systemImage: "person.crop.circle.badge.clock")
          .font(.headline)

        Text("Your saved trips remain available while Roundhouse reconnects your account.")
          .font(.subheadline)
          .foregroundStyle(Color.ttTextSecondary)
      } else if let user = account.currentUser {
        HStack(spacing: 12) {
          Image(systemName: "person.crop.circle.fill")
            .font(.title2)
            .foregroundStyle(Color.ttRouteActive)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(user.preferredName)
              .font(.headline)
            if let email = user.email {
              Text(email)
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
            }
            Text("Signed in with \(user.providers.map(\.displayName).joined(separator: ", "))")
              .font(.caption)
              .foregroundStyle(Color.ttTextSecondary)
          }
        }

        Button {
          Task { await account.signOut() }
        } label: {
          Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
        }
        .disabled(account.isWorking)
      } else if account.restoreErrorMessage != nil {
        Label("Couldn't restore your account", systemImage: "wifi.exclamationmark")
          .font(.headline)
          .foregroundStyle(Color.ttStatusDelayed)

        Text("Your saved trips are safe on this device. Check your connection and try again.")
          .font(.subheadline)
          .foregroundStyle(Color.ttTextSecondary)

        Button {
          Task { await account.restore() }
        } label: {
          Label("Try Account Restore Again", systemImage: "arrow.clockwise")
        }
      } else {
        Label("Using Roundhouse as a Guest", systemImage: "person.crop.circle")
          .font(.headline)

        Text("Track trains, view live details, and save trips on this device without an account.")
          .font(.subheadline)
          .foregroundStyle(Color.ttTextSecondary)

        Button {
          presentsSignIn = true
        } label: {
          Label("Sign In or Create Account", systemImage: "person.crop.circle.badge.plus")
        }
      }
    }
    .trainTrackerRowSurface()
  }

  private var supportSection: some View {
    Section("Support & About") {
      Link(destination: TrainTrackerSettingsLinks.support) {
        Label("Help & Support", systemImage: "questionmark.circle")
      }
      Link(destination: TrainTrackerSettingsLinks.source) {
        Label("Source Code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
      }
      SupportRoundhouseTipRow()
      Link(destination: TrainTrackerSettingsLinks.privacy) {
        Label("Privacy Policy", systemImage: "hand.raised")
      }
      ShareLink(item: TrainTrackerSettingsLinks.website) {
        Label("Share Roundhouse", systemImage: "square.and.arrow.up")
      }
      LabeledContent {
        Text(appVersion)
          .foregroundStyle(Color.ttTextSecondary)
      } label: {
        Label("Version", systemImage: "info.circle")
          .labelStyle(SettingsTileLabelStyle())
      }
    }
    .trainTrackerRowSurface()
  }

  @ViewBuilder
  private var accountDataSection: some View {
    if account.currentUser != nil {
      Section {
        Button("Delete Account", role: .destructive) {
          confirmsAccountDeletion = true
        }
        .disabled(account.isWorking)
      } header: {
        Text("Account Data")
      } footer: {
        Text("Deleting your account permanently removes server-side account data. Trips saved on this \(deviceName) remain available here.")
          .foregroundStyle(Color.ttTextPrimary)
      }
      .trainTrackerRowSurface()
    }
  }

  private var appVersion: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    return switch (version, build) {
    case let (.some(version), .some(build)): "\(version) (\(build))"
    case let (.some(version), .none): version
    default: "Unknown"
    }
  }

  private func openNotificationSettings() {
    let notificationURL = URL(string: UIApplication.openNotificationSettingsURLString)
    let appURL = URL(string: UIApplication.openSettingsURLString)
    if let url = notificationURL ?? appURL { openURL(url) }
  }

  private func openAppSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
  }

  private func refreshNotificationAccess() async {
    #if DEBUG
      if let preview = TrainTrackerNotificationAccess.preview(
        arguments: ProcessInfo.processInfo.arguments
      ) {
        notificationAccess = preview
        return
      }
    #endif
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    notificationAccess = TrainTrackerNotificationAccess(settings.authorizationStatus)
  }

  private func retryJourneyPlanRecovery(_ component: JourneyPlanStorageComponent) {
    do {
      try planLibrary.retryRecovery()
      if planLibrary.recoveryIssues.contains(where: { $0.component == component }) {
        recoveryErrorMessage = "Roundhouse still can't read this data. You can export it before choosing Reset."
      }
    } catch {
      recoveryErrorMessage = error.localizedDescription
    }
  }

  private func exportJourneyPlanRecovery(_ component: JourneyPlanStorageComponent) {
    do {
      recoveryDocument = JourneyPlanRecoveryDocument(
        data: try planLibrary.preservedRecoveryPayload(for: component)
      )
      recoveryExportFilename = "TrainTracker-\(component.exportName)-Recovery.bin"
      presentsRecoveryExport = true
    } catch {
      recoveryErrorMessage = error.localizedDescription
    }
  }

  private func resetJourneyPlanRecovery(_ component: JourneyPlanStorageComponent) {
    do {
      try planLibrary.resetRecovery(for: component)
      recoveryResetComponent = nil
    } catch {
      recoveryErrorMessage = error.localizedDescription
    }
  }

  private func retryTripArchiveRecovery() {
    do {
      try library.retryTripArchiveRecovery()
      if library.tripArchiveRecoveryRequired {
        recoveryErrorMessage = "Roundhouse still can't read these saved trains. Export the preserved data before choosing Reset."
      }
    } catch {
      recoveryErrorMessage = error.localizedDescription
    }
  }

  private func exportTripArchiveRecovery() {
    do {
      recoveryDocument = JourneyPlanRecoveryDocument(
        data: try library.preservedTripArchiveRecoveryPayload()
      )
      recoveryExportFilename = "TrainTracker-Saved-Trains-Recovery.bin"
      presentsRecoveryExport = true
    } catch {
      recoveryErrorMessage = error.localizedDescription
    }
  }

  private func resetTripArchiveRecovery() {
    do {
      try library.resetTripArchiveRecovery()
    } catch {
      recoveryErrorMessage = error.localizedDescription
    }
  }

}

private extension JourneyPlanStorageRecoveryIssue {
  var recoveryDescription: String {
    switch (component, failure) {
    case (_, .storageUnavailable):
      "Saved journey data is temporarily unavailable. Unlock the device and try reading again. The original data has not been changed."
    case (.plans, .corruptData):
      "Roundhouse can't read your saved Journey Plans. The original data is unchanged, and Journey Plan editing is paused."
    case let (.plans, .unsupportedVersion(version)):
      "These Journey Plans were written by storage version \(version), which this app can't read. The original data is unchanged."
    case (.transactionJournal, .corruptData):
      "Roundhouse can't read an unfinished Journey Plan save. The original data is unchanged, and Journey Plan editing is paused."
    case let (.transactionJournal, .unsupportedVersion(version)):
      "The Journey Plan save journal uses storage version \(version), which this app can't read. The original data is unchanged."
    }
  }
}

private extension JourneyPlanStorageComponent {
  var resetTitle: String {
    switch self {
    case .plans: "Journey Plans"
    case .transactionJournal: "Save Journal"
    }
  }

  var exportName: String {
    switch self {
    case .plans: "Journey-Plans"
    case .transactionJournal: "Journey-Save-Journal"
    }
  }

  var resetConfirmationMessage: String {
    switch self {
    case .plans:
      "This permanently removes only the unreadable saved Journey Plans. Individually saved trains remain. Export the recovery data first if you may need it later."
    case .transactionJournal:
      "This permanently removes only the unreadable Journey Plan save journal. Saved plans and trains remain. Export the recovery data first if you may need it later."
    }
  }
}

private struct JourneyPlanRecoveryDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.data]

  var data: Data = Data()

  init(data: Data = Data()) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

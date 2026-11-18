import SwiftUI
import UserNotifications

enum TrainTrackerNotificationAccess: Equatable {
  case checking
  case notRequested
  case enabled
  case disabled

  init(_ status: UNAuthorizationStatus) {
    switch status {
    case .notDetermined:
      self = .notRequested
    case .authorized, .provisional, .ephemeral:
      self = .enabled
    case .denied:
      self = .disabled
    @unknown default:
      self = .disabled
    }
  }

  #if DEBUG
    static func preview(arguments: [String]) -> Self? {
      if arguments.contains("-SettingsPreviewNotificationsEnabled") { return .enabled }
      if arguments.contains("-SettingsPreviewNotificationsDisabled") { return .disabled }
      if arguments.contains("-SettingsPreviewNotificationsNotRequested") { return .notRequested }
      return nil
    }
  #endif

  var title: String {
    switch self {
    case .checking: "Checking"
    case .notRequested: "Not Set"
    case .enabled: "On"
    case .disabled: "Off"
    }
  }

  var detail: String {
    switch self {
    case .checking:
      "Checking notification access."
    case .notRequested:
      "Roundhouse asks when you choose to track a train."
    case .enabled:
      "Delay and platform-change alerts can arrive."
    case .disabled:
      "Turn on notifications to receive train changes."
    }
  }

  var systemImage: String {
    switch self {
    case .checking, .notRequested: "bell.badge"
    case .enabled: "bell.badge.fill"
    case .disabled: "bell.slash.fill"
    }
  }

  /// Icon and wash tint. Decorative, so it keeps the route teal.
  var tint: Color {
    switch self {
    case .checking, .notRequested: .ttRouteActive
    case .enabled: .ttStatusOnTime
    case .disabled: .ttStatusDelayed
    }
  }

  /// Tint for the small state label, which must clear 4.5:1 on the brand-subtle readiness row.
  var textTint: Color {
    switch self {
    case .checking, .notRequested: .ttTextOperational
    case .enabled: .ttStatusOnTime
    case .disabled: .ttStatusDelayed
    }
  }
}

struct TrainTrackerSettingsReadiness {
  let savedTripCount: Int
  let notificationAccess: TrainTrackerNotificationAccess
  let tripArchiveRecoveryRequired: Bool
  /// "iPhone", "iPad" or "Mac": where saved trips live. See `TrainTrackerDeviceName`.
  let deviceName: String

  init(
    savedTripCount: Int,
    notificationAccess: TrainTrackerNotificationAccess,
    tripArchiveRecoveryRequired: Bool = false,
    deviceName: String = "iPhone"
  ) {
    self.savedTripCount = savedTripCount
    self.notificationAccess = notificationAccess
    self.tripArchiveRecoveryRequired = tripArchiveRecoveryRequired
    self.deviceName = deviceName
  }

  var title: String {
    if tripArchiveRecoveryRequired { return "Saved trains need recovery" }
    if notificationAccess == .checking { return "Checking your setup…" }
    if notificationAccess == .disabled { return "Alerts are off" }
    if notificationAccess == .notRequested, savedTripCount > 0 { return "Finish alert setup" }
    return savedTripCount == 0 ? "Ready for your next train" : "Tracking is ready"
  }

  var detail: String {
    if tripArchiveRecoveryRequired {
      return "Saved-train changes are paused while Roundhouse recovers the unreadable archive."
    }
    switch notificationAccess {
    case .checking:
      return "Your saved trips remain available while Roundhouse checks notification access."
    case .disabled:
      return "Saved trips still refresh normally. Turn on notifications to receive delay and platform changes."
    case .notRequested where savedTripCount > 0:
      return "Your trips are saved. Change alerts will be offered when you track your next train."
    case .enabled where savedTripCount > 0:
      return "\(savedTripText) saved on this \(deviceName), with change alerts ready."
    case .notRequested, .enabled:
      return "Search for a train to save it and follow live updates."
    }
  }

  var savedTripText: String {
    if tripArchiveRecoveryRequired { return "Unknown" }
    return "\(savedTripCount) \(savedTripCount == 1 ? "trip" : "trips")"
  }

  var savedTripDetail: String {
    if tripArchiveRecoveryRequired {
      return "The saved-train archive needs recovery. Its original data is preserved on this \(deviceName)."
    }
    return "Available on this \(deviceName), even when you're signed out."
  }
}

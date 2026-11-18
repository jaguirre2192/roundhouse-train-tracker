enum PushDeliveryWarningContext: Equatable {
    case savedTrains
    case previousTrains
    case deviceSetup
}

struct PushDeliveryWarningPresentation: Equatable {
    enum Action: Equatable {
        case openNotificationSettings
        case retry
    }

    let title: String
    let message: String
    let actionTitle: String
    let action: Action
    let systemImage: String
    let accessibilityHint: String

    init(
        reason: PushDeliveryWarningReason?, deviceName: String = "iPhone",
        context: PushDeliveryWarningContext = .savedTrains
    ) {
        let failureTitle: String
        let failureMessage: String
        let failureAccessibilityHint: String
        switch reason {
        case .backendSetupRejected:
            failureTitle = "Train alerts need attention"
            failureMessage = "Roundhouse's service couldn't accept the alert setup. Try again."
            actionTitle = "Try Again"
            action = .retry
            systemImage = "bell.badge.exclamationmark.fill"
            failureAccessibilityHint = "Retries alert setup for saved trains"
        case .backendRateLimited:
            failureTitle = "Train alerts are taking longer"
            failureMessage = "The alert service asked us to wait. Roundhouse will retry automatically."
            actionTitle = "Try Again"
            action = .retry
            systemImage = "bell.badge.exclamationmark.fill"
            failureAccessibilityHint = "Retries alert setup when the service is ready"
        case .authorizationDenied:
            failureTitle = "Train alerts are off"
            failureMessage = "Turn on notifications in Settings to receive delay and platform-change alerts."
            actionTitle = "Open Notification Settings"
            action = .openNotificationSettings
            systemImage = "bell.slash.fill"
            failureAccessibilityHint = "Opens this app’s notification settings"
        case .authorizationFailed:
            failureTitle = "Couldn’t check notification access"
            failureMessage = "Roundhouse couldn’t verify notification access. Try again."
            actionTitle = "Try Again"
            action = .retry
            systemImage = "bell.badge.exclamationmark.fill"
            failureAccessibilityHint = "Checks notification access and synchronizes train alerts again"
        case .remoteRegistrationFailed:
            failureTitle = "Train alerts couldn’t connect"
            failureMessage = "This \(deviceName) couldn’t register for alerts. Try again."
            actionTitle = "Try Again"
            action = .retry
            systemImage = "bell.badge.exclamationmark.fill"
            failureAccessibilityHint = "Registers this \(deviceName) for train alerts again"
        case .backendSynchronizationFailed, nil:
            failureTitle = "Train alerts aren’t synced"
            failureMessage = "Alert setup hasn’t reached Roundhouse’s service. Try again."
            actionTitle = "Try Again"
            action = .retry
            systemImage = "bell.badge.exclamationmark.fill"
            failureAccessibilityHint = "Synchronizes alerts for tracked trains again"
        }

        switch context {
        case .savedTrains:
            title = failureTitle
            message = "Your saved trains are still tracked. \(failureMessage)"
        case .previousTrains:
            // Removed IDs prove these updates concern previous watches; they do not prove
            // which operation failed, so don't claim a particular removal was attempted.
            title = "Previous train alerts need attention"
            message = "This update concerns alerts for trains you no longer follow. \(failureMessage)"
        case .deviceSetup:
            title = reason == .authorizationDenied ? "Notifications are off" : "Notification setup needs attention"
            message = failureMessage
        }
        if action == .openNotificationSettings || context == .savedTrains {
            accessibilityHint = failureAccessibilityHint
        } else {
            accessibilityHint = context == .previousTrains
                ? "Retries alert updates for previous trains"
                : "Retries notification setup on this \(deviceName)"
        }
    }
}

/// Explains trains the alert service refused while it kept serving the others.
struct PushTripRejectionPresentation: Equatable {
    let title: String
    let message: String

    init?(rejections: [PushTripAlertRejection]) {
        guard !rejections.isEmpty else { return nil }
        let count = rejections.count
        let trains = count == 1 ? "1 train" : "\(count) trains"
        if rejections.contains(.quotaExceeded) {
            title = "Alert limit reached"
            message = "Alerts cover up to 24 trains at a time, so \(trains) won't get alerts. Remove a train you no longer need and alerts will turn on automatically."
        } else {
            title = count == 1 ? "No alerts for 1 train" : "No alerts for \(count) trains"
            message = "Your trains are still tracked, but Roundhouse's service couldn't set up alerts for \(trains). Live details still update in the app."
        }
    }
}

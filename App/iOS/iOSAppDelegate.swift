import UIKit
import UserNotifications

final class iOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in PushRegistrationBridge.shared.receive(deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in PushRegistrationBridge.shared.fail(error) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await keepTrainAlert(notification)
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await keepTrainAlert(response.notification)
    }

    private nonisolated func keepTrainAlert(_ notification: UNNotification) async {
        guard !LaunchFixtures.isActive, let alert = TripDeliveredAlert(notification) else { return }
        await MainActor.run { try? TrainJourneyRuntime.shared.library.keepDeliveredAlerts([alert]) }
    }
}

import Foundation

/// Whether this launch runs on fixture data: an App Store preview, a QA scenario or a UI test.
/// Anything that writes to the rider's own records or reaches outside the app checks this first,
/// so a preview train never lands in their Travel Log, sets an alarm or starts a Live Activity.
enum LaunchFixtures {
    static let isActive: Bool = ProcessInfo.processInfo.arguments.dropFirst().contains { argument in
        argument.hasPrefix("-") && (argument.contains("Preview") || argument.contains("QA"))
    }
}

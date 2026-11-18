import UIKit

/// The device noun copy uses ("saved on this iPad"). Decided by the idiom, never the size class:
/// an iPad in a narrow split is still an iPad, and iPhone Duo is an iPhone on either display.
enum TrainTrackerDeviceName {
  @MainActor static var current: String {
    name(for: UIDevice.current.userInterfaceIdiom, isiOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac)
  }

  static func name(for idiom: UIUserInterfaceIdiom, isiOSAppOnMac: Bool) -> String {
    if isiOSAppOnMac { return "Mac" }
    switch idiom {
    case .pad: return "iPad"
    case .mac: return "Mac"
    default: return "iPhone"
    }
  }
}

/// Hardware that changes where the app puts its controls.
enum TrainTrackerDevice {
  /// iPhone Duo. The system gives its navigation bars a strip of their own beside the camera
  /// (on the outer display, and on the inner one in landscape), so on this phone My Trips uses
  /// the native bar there and keeps only the trains floating over the map.
  static let isDuo: Bool = duoModelIdentifiers.contains(modelIdentifier)

  /// The identifier the iPhone Duo simulator reports. Not yet checked against the hardware.
  static let duoModelIdentifiers: Set<String> = ["iPhone19,4"]

  static let modelIdentifier: String = {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  }()
}

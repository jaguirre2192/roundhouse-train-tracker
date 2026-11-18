import SwiftUI

/// Train Tracker's own symbols. They live in `Symbols.xcassets` as custom symbols, so they take a
/// font's size and weight exactly as an SF Symbol does.
enum TrainTrackerSymbol {
    /// The train, seen head on: the app's own drawing, used wherever a train is meant.
    static let train = "tt.train"

    /// Whether a symbol name is one of the app's own rather than an SF Symbol.
    static func isCustom(_ name: String) -> Bool { name.hasPrefix("tt.") }
}

extension Image {
    /// A symbol by name, whichever kind it is: the app's own symbols come from the asset catalog,
    /// everything else is an SF Symbol. For names chosen at run time.
    init(ttSymbol name: String) {
        if TrainTrackerSymbol.isCustom(name) {
            self.init(name)
        } else {
            self.init(systemName: name)
        }
    }
}

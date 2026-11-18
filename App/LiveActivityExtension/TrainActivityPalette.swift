import SwiftUI

enum TrainActivityPalette {
    static let background = Color(red: 18 / 255, green: 61 / 255, blue: 75 / 255)
    static let primary = Color(red: 255 / 255, green: 248 / 255, blue: 232 / 255)
    static let secondary = primary.opacity(0.78)
    static let accent = Color(red: 141 / 255, green: 208 / 255, blue: 215 / 255)
    /// Matches the app's on-ink route and status tokens (brand guide 1.2).
    static let route = Color(red: 93 / 255, green: 165 / 255, blue: 178 / 255)
    static let rail = primary.opacity(0.24)
    static let warning = Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)
    static let cancelled = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)

    static func status(for presentation: TrainActivityPresentation) -> Color {
        if presentation.isCancelled { return cancelled }
        if presentation.isStale { return secondary }
        if presentation.hasDelay { return warning }
        return accent
    }
}

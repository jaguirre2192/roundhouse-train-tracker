import Foundation

extension JourneySearchCopy {
    /// Capability wording for a train that is about to be saved. It names features and never
    /// borrows the tracking screen's freshness words (Live, Estimated, Timetable, Saved) as a badge.
    enum Coverage {
        static let scheduleOnly = String(localized: "Schedule only")
        static let unconfirmed = String(localized: "Live coverage not confirmed")
        static let unavailableNow = String(localized: "Updates unavailable right now")
        static let varies = String(localized: "Live coverage varies by train")
        static let details = String(localized: "Coverage details")
        static let detailsHint = String(localized: "Opens a page explaining what each country and operator provides.")
        static let checkAgain = String(localized: "Check Again")
        static let readyToSave = String(localized: "Ready to save")
        static let saveJourney = String(localized: "Save Journey")
        static let saveRoundTrip = String(localized: "Save Round Trip")
        static let featureSeparator = " · "

        static func feature(_ feature: JourneyCoverage.Feature) -> String {
            switch feature {
            case .delays: String(localized: "Live delays")
            case .cancellations: String(localized: "Cancellations")
            case .platforms: String(localized: "Platforms")
            case .position: String(localized: "Train location")
            }
        }

        static func notProvided(_ feature: JourneyCoverage.Feature) -> String {
            switch feature {
            case .delays: String(localized: "No live delays from this source.")
            case .cancellations: String(localized: "No cancellation notices from this source.")
            case .platforms: String(localized: "No platforms from this source.")
            case .position: String(localized: "No train location from this source.")
            }
        }

        static func notConfirmed(_ feature: JourneyCoverage.Feature) -> String {
            switch feature {
            case .delays: String(localized: "Live delays not confirmed.")
            case .cancellations: String(localized: "Cancellation notices not confirmed.")
            case .platforms: String(localized: "Platforms not confirmed.")
            case .position: String(localized: "Train location not confirmed.")
            }
        }

        static func scope(_ name: String) -> String { String(localized: "Covers \(name) only.") }

        static func scheduleOnlyDetail(trains count: Int) -> String {
            count == 1
                ? String(localized: "Live tracking isn't connected for this train. You can still save the schedule.")
                : String(localized: "Live tracking isn't connected for these trains. You can still save the schedule.")
        }

        static func unconfirmedDetail(trains count: Int) -> String {
            count == 1
                ? String(localized: "The schedule is available. Live updates haven't been confirmed for this train.")
                : String(localized: "The schedule is available. Live updates haven't been confirmed for these trains.")
        }

        static func unavailableDetail(trains count: Int) -> String {
            count == 1
                ? String(localized: "Live updates couldn't be checked for this train. You can still save it.")
                : String(localized: "Live updates couldn't be checked for these trains. You can still save them.")
        }

        static func variesDetail(gaps: Int, total: Int) -> String {
            gaps == 1
                ? String(localized: "\(gaps) of \(total) trains has limited or unconfirmed live updates. Each train shows what it provides.")
                : String(localized: "\(gaps) of \(total) trains have limited or unconfirmed live updates. Each train shows what it provides.")
        }
    }
}

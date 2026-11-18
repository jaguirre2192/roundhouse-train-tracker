import Foundation

struct JourneyAccessibilityAction: Equatable {
    let label: String
    let hint: String
}

enum JourneyCommerceCopyGuard {
    private static let forbiddenPatterns = [
        #"\bprice\w*\b"#,
        #"\bcheapest\w*\b"#,
        #"\bfare\w*\b"#,
        #"\bseat[\s-]*availability\w*\b"#,
        #"\bbuy\w*\b"#,
        #"\bpurchase\w*\b"#,
        #"\bcheckout\w*\b"#,
    ]

    static func containsForbiddenCopy(_ value: String) -> Bool {
        forbiddenPatterns.contains { pattern in
            value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}

enum JourneySearchCopy {
    static let search = String(localized: "Search")
    static let outbound = String(localized: "Outbound")
    static let returnDirection = String(localized: "Return")
    static let cancel = String(localized: "Cancel")

    enum Form {
        static let route = String(localized: "Route")
        static let from = String(localized: "From")
        static let to = String(localized: "To")
        static let swap = String(localized: "Swap")
        static let outbound = JourneySearchCopy.outbound
        static let searchBy = String(localized: "Search by")
        static let departAt = String(localized: "Depart At")
        static let arriveBy = String(localized: "Arrive By")
        static let dateAndTime = String(localized: "Date and time")
        static let addReturn = String(localized: "Add Return")
        static let returnDateAndTime = String(localized: "Return date and time")
        static let options = String(localized: "Options")
        static let directOnly = String(localized: "Direct only")
        static let maximumChanges = String(localized: "Maximum changes")
        static let searchFailure = String(localized: "Train search is temporarily unavailable. Please try again.")
        static let searchOffline = String(localized: "You're offline. Check your connection and try again.")
        static let searchTimedOut = String(localized: "Train search took too long. Please try again.")
        static let searchRateLimited = String(localized: "Too many searches. Wait a moment and try again.")
        static let searchInvalidRequest = String(localized: "These journey details are no longer valid. Choose the stations again and retry.")
        static let searchInvalidResponse = String(localized: "Train search returned an unexpected response. Please try again.")
        static let searchingTrains = String(localized: "Searching Trains…")
        static let searchTrains = String(localized: "Search Trains")
        static let qualification = String(localized: "Mainline trains only. Coverage and live detail vary by country and operator.")
        static let choose = String(localized: "Choose")
        static let notSelected = String(localized: "not selected")
        static let placePickerHint = String(localized: "Opens city and station search")
        static let liveStationDepartures = String(localized: "Live station departures")
        static let splitPlaceholderTitle = String(localized: "Find a Train")
        static let splitPlaceholderMessage = String(localized: "Choose where you're traveling from and to. Departures appear here, beside your search.")
        static let findingOutbound = String(localized: "Finding outbound trains")
        static let findingReturn = String(localized: "Finding return trains")

        static func upTo(_ count: Int) -> String { "Up to \(count)" }
        static func placeLabel(title: String, placeName: String?) -> String {
            "\(title), \(placeName ?? notSelected)"
        }

        static func searchFailureMessage(for reason: JourneySearchFailureReason?) -> String {
            switch reason {
            case .offline: searchOffline
            case .timedOut: searchTimedOut
            case .rateLimited: searchRateLimited
            case .invalidRequest: searchInvalidRequest
            case .invalidResponse: searchInvalidResponse
            case .serviceUnavailable, .none: searchFailure
            }
        }
    }

    enum PlacePicker {
        static let allStations = String(localized: "All stations")
        static let city = String(localized: "City")
        static let station = String(localized: "Station")
        static let timeZone = String(localized: "Time zone")
        static let chooseFrom = String(localized: "Choose From")
        static let chooseTo = String(localized: "Choose To")
        static let searchPrompt = String(localized: "City or station")
        static let keepTyping = String(localized: "Keep typing")
        static let minimumQuery = String(localized: "Enter at least two characters to search cities and stations.")
        static let searching = String(localized: "Searching places…")
        static let failure = String(localized: "We couldn't search places. Check your connection and try again.")
        static let tryAgain = String(localized: "Try Again")
        static let places = String(localized: "Places")
        static let emptyTitle = String(localized: "Find a city or station")
        static let emptyDescription = String(localized: "Search for a mainline city or an exact station.")
        static let recent = String(localized: "Recent")
        static let clearRecents = String(localized: "Clear Recent Places")

        static func cityTitle(_ name: String) -> String {
            let suffix = "— \(allStations)"
            let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.hasSuffix(suffix) ? value : "\(value) \(suffix)"
        }
    }

    enum Results {
        static let chooseOutbound = String(localized: "Choose Outbound")
        static let chooseReturn = String(localized: "Choose Return")
        static let departingAfter = String(localized: "Depart after")
        static let arrivingBy = String(localized: "Arrive by")
        static let departingAfterShort = String(localized: "After")
        static let arrivingByShort = String(localized: "By")
        static let earlier = String(localized: "Earlier departures")
        static let later = String(localized: "Later departures")
        static let noDirectTitle = String(localized: "No direct trains on this page")
        static let noTrainsTitle = String(localized: "No trains found")
        static let noDirectDescription = String(localized: "Turn off Direct only to see connecting journeys.")
        static let noTrainsDescription = String(localized: "Try an earlier or later search window.")
        static let serviceNotes = String(localized: "Service notes")
        static let journeyUnavailable = String(localized: "Journey unavailable")
        static let filter = String(localized: "Filters")
        static let sortBy = String(localized: "Sort results")
        static let sortControl = String(localized: "Sort")
        static let sortDeparture = String(localized: "Departure")
        static let sortFastest = String(localized: "Fastest")
        static let sortFewestChanges = String(localized: "Fewest changes")
        static let directFilterOnHint = String(localized: "Showing only journeys with no changes")
        static let directFilterOffHint = String(localized: "Includes journeys with changes")
        static let selectedOutbound = String(localized: "Selected outbound")
        static let earliestValidAction = String(localized: "Search from earliest valid time")
        static let editReturn = String(localized: "Edit Return")
        static let continueOneWay = String(localized: "Continue One-Way")
        static let returnUnavailableTitle = String(localized: "Return search unavailable")
        static let returnTooEarlyTitle = String(localized: "Return time is too early")
        static let noReturnTitle = String(localized: "No return trains found")
        static let returnUnavailableDescription = String(localized: "Your outbound is still selected. Edit the return or continue with a one-way journey.")
        static let noReturnDescription = String(localized: "Your outbound is still selected. Try another return time or continue one-way.")

        static func returnTooEarlyDescription(time: String) -> String {
            "The return must leave after your outbound arrives. The earliest valid search time is \(time)."
        }

        static func selectedOutboundLabel(_ optionLabel: String) -> String {
            "\(selectedOutbound), \(optionLabel)"
        }

        static func optionCount(_ count: Int) -> String {
            "\(count) \(count == 1 ? "option" : "options")"
        }

        static func maximumChangesLabel(_ count: Int) -> String {
            "Up to \(count) \(count == 1 ? "change" : "changes")"
        }
    }

    enum Detail {
        static let title = String(localized: "Journey Details")
        static let departure = String(localized: "Departure")
        static let arrival = String(localized: "Arrival")
        static let sourceHeading = String(localized: "Schedule sources")
        static let sourceQualification = String(localized: "Sources describe this result only. Operator, route, realtime, and platform coverage vary.")
        static let scheduled = String(localized: "Timetable")
        static let cancelledCall = String(localized: "Canceled call")
        static let trackabilityUnavailable = String(localized: "Trackability unavailable")
        static let board = String(localized: "Board")
        static let alight = String(localized: "Alight")
        static let timeUnavailable = String(localized: "Time unavailable")
        static let stationUnavailable = String(localized: "Station unavailable")
        static let stationTransfer = String(localized: "Station transfer")
        static let transferWalk = String(localized: "Transfer walk")
        static let sourceLinkHint = String(localized: "Opens source information in the browser")

        static func scheduledTime(_ value: String) -> String { "\(scheduled) \(value)" }
    }

    enum Review {
        static let title = String(localized: "Review Journey")
        static let detailsChangedTitle = String(localized: "Journey details changed")
        static let detailsChangedMessage = String(localized: "The tracking link expired. Retry to refresh this same journey.")
        static let unavailableTitle = String(localized: "Tracking check unavailable")
        static let unavailableMessage = String(localized: "Your schedule is still here. Retry when you're ready.")
        static let checkingTitle = String(localized: "Checking every selected train")
        static let checkingMessage = String(localized: "This resolves outbound and return trains together before anything is saved.")
        static let saveFailure = String(localized: "Journey couldn't be saved. The resolved trains are still ready—try again.")
        static let retryTrackingCheck = String(localized: "Retry tracking check")
        static let outboundTrain = String(localized: "Outbound train")
        static let returnTrain = String(localized: "Return train")
        static let selectedTrain = String(localized: "Selected train")

        static func readyCount(_ count: Int) -> String {
            "\(count) selected \(count == 1 ? "train is" : "trains are") ready."
        }
    }

    enum ReturnEditor {
        static let searchReturns = String(localized: "Search Returns")
        static let selectionPreserved = String(localized: "Your selected outbound stays saved while you adjust the return.")
        static let title = String(localized: "Edit Return")
    }

    enum Status {
        static let cancelled = String(localized: "Canceled")
        static let liveTimes = String(localized: "Live times")
        static let trackable = String(localized: "Trackable")
        static let providerCannotTrack = String(localized: "Provider cannot track this train")
        static let stationChangeRequired = String(localized: "Station change required")
        static let originUnavailable = String(localized: "Origin station unavailable")
        static let destinationUnavailable = String(localized: "Destination station unavailable")
        static let direct = String(localized: "Direct")
        static let fastest = String(localized: "Fastest")
        static let fewestChanges = String(localized: "Fewest changes")
        static let trackingAvailable = String(localized: "Tracking available")
        static let trackingUnavailable = String(localized: "Tracking unavailable")

        static func stationChange(at station: String) -> String { "Station change at \(station)" }
        static func notTrackable(reason: String) -> String { "Not trackable: \(reason)" }
        static func walkTo(_ place: String) -> String { "Walk to \(place)" }
        static func from(_ place: String) -> String { "From \(place)" }
        static func walkDuration(_ value: String) -> String { "\(value) walk" }
        static func route(from origin: String, to destination: String) -> String {
            "\(origin) to \(destination)"
        }
        static func platform(_ value: String) -> String { "Platform \(value)" }
        static func changes(_ count: Int) -> String {
            count == 0 ? direct : "\(count) \(count == 1 ? "change" : "changes")"
        }
        /// A search result has no resolved coverage, so this never promises live data.
        static func trackability(trackable: Int, total: Int) -> String {
            guard total > 0, trackable > 0 else { return trackingUnavailable }
            if trackable == total { return trackingAvailable }
            return "\(trackable) of \(total) trains trackable"
        }
    }

    enum Resolution {
        static let pushWarning = String(localized: "Journey saved. Open My Trips to retry alerts.")
        static let allReady = String(localized: "All selected trains are ready to track")
        static let partial = String(localized: "Some trains are unavailable")
        static let none = String(localized: "No trains can be tracked")
        static let trackRoundTrip = String(localized: "Track Round Trip")
        static let trackJourney = String(localized: "Track Journey")
        static let retryUnavailable = String(localized: "Retry unavailable trains")

        static func trackAvailable(count: Int) -> String {
            "Track \(count) Available \(count == 1 ? "Train" : "Trains")"
        }
        static func subsetConsent(count: Int) -> String {
            "Track only the \(count) available \(count == 1 ? "train" : "trains")"
        }
    }

    enum Plan {
        static let savedUnavailable = String(localized: "Saved journeys unavailable")
        static let savedUnavailableDescription = String(localized: "Roundhouse couldn't open your saved journey plans.")
        static let oneWayJourney = String(localized: "ONE-WAY JOURNEY")
        static let roundTrip = String(localized: "ROUND TRIP")
        static let nextTrain = String(localized: "Next train")
        static let noTrackedTrains = String(localized: "No tracked trains available")
        static let groupTitle = String(localized: "Journey group")
        static let upcomingJourneys = String(localized: "Upcoming Journeys")
        static let otherJourneys = String(localized: "Other Journeys")
        static let pastJourneys = String(localized: "Past Journeys")
        static let upcomingTrains = String(localized: "Upcoming Trains")
        static let currentTrains = String(localized: "Current Trains")
        static let currentJourneys = String(localized: "Current Journeys")
        static let fromYourInbox = String(localized: "From Your Inbox")
        static let forwardedTickets = String(localized: "Forwarded Tickets")
        static let toReview = String(localized: "To Review")
        static let continueReview = String(localized: "Continue Review")
        static let keepWithoutJourney = String(localized: "Keep Without a Journey")
        static let discardReview = String(localized: "Discard Review")
        static let reviewActions = String(localized: "Review Actions")
        static let groupRemoved = String(localized: "Journey group removed")
        static let checkingLiveData = String(localized: "Checking train details")
        static let notCheckedYet = String(localized: "Train details not checked yet")
        static func liveDataUpdated(at time: String) -> String {
            String(localized: "Train details updated \(time)")
        }
        static let otherTrains = String(localized: "Other Trains")
        static let pastTrains = String(localized: "Past Trains")
        static let groupExplanation = String(localized: "Removing the group keeps every train tracked. Stop tracking trains only from the separate review below.")
        static let removeGroup = String(localized: "Remove Journey Group")
        static let stopTrackingJourneyTrains = String(localized: "Stop Tracking Journey Trains")
        static let removalFailure = String(localized: "The journey group couldn’t be removed. Your tracked trains are unchanged. Try again.")
        static let trainRemovalFailure = String(localized: "The journey trains couldn’t be removed. The journey group and tracked trains are unchanged. Try again.")
        static let willStopTracking = String(localized: "Will stop tracking")
        static let noRemovableTrains = String(localized: "No trains can be removed from this group.")
        static let willRemainTracked = String(localized: "Will remain tracked")
        static let noPreservedTrains = String(localized: "No trains need preservation.")
        static let noLongerTracked = String(localized: "No longer tracked")
        static let allStillTracked = String(localized: "Every journey train is still in My Trips.")
        static let stopTrackingTitle = String(localized: "Stop tracking trains")
        static let removeGroupTitle = String(localized: "Remove journey group")
        static let reviewBeforeRemoving = String(localized: "Review before removing")
        static let journeyTrain = String(localized: "Journey train")
        static let train = String(localized: "Train")
        static let tracked = String(localized: "Tracked")
        static let shared = String(localized: "Tracked by another journey")
        static let preExisting = String(localized: "Tracked before this journey")
        static let sharedAndPreExisting = String(localized: "Tracked before and used by another journey")
        static let removeWithTrainsWarning = String(localized: "This removes the journey group and stops alerts for eligible trains. Trains shared with another journey or tracked before this journey stay in My Trips.")
        static let removeGroupWarning = String(localized: "This removes the journey group. Any trains still in My Trips remain tracked.")
        static let pushTitle = String(localized: "Train alerts need attention")
        static let pushMessage = String(localized: "Your trains are still tracked, but alerts aren’t synchronized. Check notification access, then retry.")
        static let retryAlerts = String(localized: "Retry Alert Setup")

        static func childCount(_ count: Int) -> String { "\(count) \(count == 1 ? "train" : "trains")" }
        static func stopTrackingCount(_ count: Int) -> String {
            "Stop Tracking \(count) \(count == 1 ? "Train" : "Trains")"
        }
        static func departs(date: String, time: String) -> String {
            "Departs \(date) at \(time)"
        }
        static func arrives(date: String, time: String) -> String {
            "Arrives \(date) at \(time)"
        }
    }

    enum Accessibility {
        static let swapPlaces = JourneyAccessibilityAction(
            label: "Swap origin and destination",
            hint: "Reverses the selected route"
        )
        static let clearRecents = JourneyAccessibilityAction(
            label: PlacePicker.clearRecents,
            hint: "Removes recent journey places from this device"
        )
        static let retryPlaceSearch = JourneyAccessibilityAction(
            label: PlacePicker.tryAgain,
            hint: "Repeats the city and station search"
        )
        static let retryTrackingCheck = JourneyAccessibilityAction(
            label: Review.retryTrackingCheck,
            hint: "Checks every selected train again"
        )
        static let removeJourneyGroup = JourneyAccessibilityAction(
            label: Plan.removeGroup,
            hint: "Removes the grouping and keeps its trains tracked"
        )
        static let stopTrackingJourneyTrains = JourneyAccessibilityAction(
            label: Plan.stopTrackingJourneyTrains,
            hint: "Opens a review of trains that can stop being tracked"
        )
        static let retryAlertSetup = JourneyAccessibilityAction(
            label: Plan.retryAlerts,
            hint: "Tries to synchronize alerts for tracked trains again"
        )
        static let earliestValidReturn = JourneyAccessibilityAction(
            label: Results.earliestValidAction,
            hint: "Uses the first valid time after the outbound arrival"
        )

        static func selectResult(
            direction: String,
            optionLabel: String
        ) -> JourneyAccessibilityAction {
            JourneyAccessibilityAction(
                label: "Select \(direction.lowercased()) journey, \(optionLabel)",
                hint: "Continues with this \(direction.lowercased()) journey"
            )
        }
        static func resultDetails(departure: String) -> JourneyAccessibilityAction {
            JourneyAccessibilityAction(
                label: "Details for \(departure) departure",
                hint: "Opens the train, stop, and schedule-source details"
            )
        }
        static func resultPage(title: String, direction: String) -> JourneyAccessibilityAction {
            JourneyAccessibilityAction(
                label: "Load \(title.lowercased()) \(direction.lowercased()) journeys",
                hint: "Requests another schedule window"
            )
        }
        static func departure(time: String, station: String) -> String {
            "Departs \(time) from \(station)"
        }
        static func arrival(time: String, daySuffix: String, station: String) -> String {
            "Arrives \(time)\(daySuffix) at \(station)"
        }
        static func duration(_ value: String) -> String { "Duration \(value)" }
    }

    static var allValues: [String] {
        let values = [
            search, outbound, returnDirection, cancel,
            Form.route, Form.from, Form.to, Form.swap, Form.searchBy, Form.departAt, Form.arriveBy,
            Form.dateAndTime, Form.addReturn, Form.returnDateAndTime, Form.options, Form.directOnly,
            Form.maximumChanges, Form.searchFailure, Form.searchOffline, Form.searchTimedOut,
            Form.searchRateLimited, Form.searchInvalidRequest, Form.searchInvalidResponse,
            Form.searchingTrains, Form.searchTrains,
            Form.qualification, Form.choose, Form.notSelected, Form.placePickerHint,
            Form.liveStationDepartures, Form.findingOutbound, Form.findingReturn,
            Form.splitPlaceholderTitle, Form.splitPlaceholderMessage,
            Form.upTo(4), Form.placeLabel(title: Form.from, placeName: nil),
            Form.placeLabel(title: Form.to, placeName: "Paris"),
            PlacePicker.allStations, PlacePicker.city, PlacePicker.station, PlacePicker.timeZone,
            PlacePicker.chooseFrom,
            PlacePicker.chooseTo, PlacePicker.searchPrompt, PlacePicker.keepTyping, PlacePicker.minimumQuery,
            PlacePicker.searching, PlacePicker.failure, PlacePicker.tryAgain, PlacePicker.places,
            PlacePicker.emptyTitle, PlacePicker.emptyDescription, PlacePicker.recent, PlacePicker.clearRecents,
            PlacePicker.cityTitle("Paris"), Results.chooseOutbound, Results.chooseReturn,
            Results.departingAfter, Results.arrivingBy, Results.departingAfterShort,
            Results.arrivingByShort, Results.earlier, Results.later, Results.noDirectTitle,
            Results.noTrainsTitle, Results.noDirectDescription, Results.noTrainsDescription,
            Results.serviceNotes, Results.journeyUnavailable, Results.filter, Results.sortBy,
            Results.sortControl,
            Results.sortDeparture, Results.sortFastest, Results.sortFewestChanges, Results.selectedOutbound,
            Results.directFilterOnHint, Results.directFilterOffHint,
            Results.earliestValidAction, Results.editReturn, Results.continueOneWay,
            Results.returnUnavailableTitle, Results.returnTooEarlyTitle, Results.noReturnTitle,
            Results.returnUnavailableDescription, Results.noReturnDescription,
            Results.returnTooEarlyDescription(time: "Jul 24, 8:00 AM"),
            Results.selectedOutboundLabel("8:25 AM to 10:12 AM"),
            Results.optionCount(2), Results.maximumChangesLabel(4),
            Detail.title, Detail.departure, Detail.arrival, Detail.sourceHeading,
            Detail.sourceQualification, Detail.scheduled,
            Detail.cancelledCall, Detail.trackabilityUnavailable, Detail.board, Detail.alight,
            Detail.timeUnavailable, Detail.stationUnavailable, Detail.stationTransfer,
            Detail.transferWalk, Detail.sourceLinkHint, Detail.scheduledTime("8:25 AM"),
            Review.title, Review.detailsChangedTitle, Review.detailsChangedMessage, Review.unavailableTitle,
            Review.unavailableMessage, Review.checkingTitle, Review.checkingMessage, Review.saveFailure,
            Review.retryTrackingCheck, Review.outboundTrain, Review.returnTrain, Review.selectedTrain,
            Review.readyCount(2), ReturnEditor.searchReturns, ReturnEditor.selectionPreserved,
            ReturnEditor.title, Status.cancelled, Status.liveTimes, Status.trackable,
            Status.providerCannotTrack, Status.stationChangeRequired, Status.originUnavailable,
            Status.destinationUnavailable, Status.direct, Status.fastest, Status.fewestChanges,
            Status.trackingAvailable, Status.trackingUnavailable,
            Status.stationChange(at: "Paris Nord"), Status.notTrackable(reason: "No live feed"),
            Status.walkTo("Paris Est"), Status.from("Paris Nord"), Status.platform("4"),
            Status.walkDuration("8 min"), Status.route(from: "Paris Nord", to: "Paris Est"),
            Status.changes(0), Status.changes(1), Status.changes(2),
            Status.trackability(trackable: 1, total: 1),
            Status.trackability(trackable: 1, total: 2),
            Resolution.pushWarning, Resolution.allReady, Resolution.partial, Resolution.none,
            Resolution.trackRoundTrip, Resolution.trackJourney, Resolution.retryUnavailable,
            Resolution.trackAvailable(count: 2), Resolution.subsetConsent(count: 2),
            Plan.savedUnavailable, Plan.savedUnavailableDescription, Plan.oneWayJourney, Plan.roundTrip,
            Plan.nextTrain, Plan.noTrackedTrains, Plan.groupTitle, Plan.upcomingJourneys,
            Plan.groupExplanation,
            Plan.removeGroup, Plan.stopTrackingJourneyTrains, Plan.removalFailure,
            Plan.trainRemovalFailure, Plan.willStopTracking, Plan.noRemovableTrains,
            Plan.willRemainTracked, Plan.noPreservedTrains, Plan.noLongerTracked,
            Plan.allStillTracked, Plan.stopTrackingTitle, Plan.removeGroupTitle,
            Plan.reviewBeforeRemoving, Plan.journeyTrain, Plan.train, Plan.tracked, Plan.shared,
            Plan.preExisting, Plan.sharedAndPreExisting, Plan.removeWithTrainsWarning,
            Plan.removeGroupWarning, Plan.pushTitle, Plan.pushMessage, Plan.retryAlerts,
            Plan.childCount(1), Plan.childCount(2), Plan.stopTrackingCount(1),
            Plan.stopTrackingCount(2), Plan.departs(date: "Jul 24", time: "8:25 AM"),
            Plan.arrives(date: "Jul 24", time: "10:12 AM"),
            Accessibility.departure(time: "8:25 AM", station: "Paris Nord"),
            Accessibility.arrival(time: "10:12 AM", daySuffix: "", station: "Brussels Midi"),
            Accessibility.duration("1 hr 47 min"), JourneyDataSources.qualification,
            JourneyDataSources.sectionTitle, JourneyDataSources.additionalSourcesTitle,
            JourneyDataSources.transitousTitle, JourneyDataSources.openStreetMapTitle,
            JourneyDataSources.operatorCoverageTitle, JourneyDataSources.openStreetMapContributorsTitle,
            JourneyDataSources.linkHint(JourneyDataSources.transitousTitle),
        ] + JourneyDataSources.additional.map(\.title) + [
            Accessibility.swapPlaces, Accessibility.clearRecents, Accessibility.retryPlaceSearch,
            Accessibility.resultDetails(departure: "8:25 AM"),
            Accessibility.resultPage(title: Results.earlier, direction: outbound),
            Accessibility.selectResult(
                direction: outbound,
                optionLabel: "Departs 8:25 AM, arrives 10:12 AM"
            ),
            Accessibility.retryTrackingCheck,
            Accessibility.removeJourneyGroup, Accessibility.stopTrackingJourneyTrains,
            Accessibility.retryAlertSetup, Accessibility.earliestValidReturn,
        ].flatMap { [$0.label, $0.hint] }

        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

struct JourneyDataSourceLink: Identifiable, Equatable {
    let title: String
    let destination: URL
    var id: String { title }
}

enum JourneyDataSources {
    static let transitousURL = URL(string: "https://transitous.org")!
    static let openStreetMapURL = URL(string: "https://www.openstreetmap.org/copyright")!
    static let feedDirectoryURL = URL(string: "https://transitous.org/sources/")!
    static let coverageURL = URL(
        string: "https://api.gettraintracker.com/v1/coverage"
    )!
    static let qualification = "Schedule, operator, realtime, and platform coverage varies by route, country, and operator. No source covers every train."
    static let sectionTitle = "Data Sources"
    static let additionalSourcesTitle = "Additional live-data sources"
    static let transitousTitle = "Transitous"
    static let openStreetMapTitle = "OpenStreetMap"
    static let openStreetMapContributorsTitle = "OpenStreetMap contributors"
    static let operatorCoverageTitle = "Operator and feed coverage"
    static let settings = [
        JourneyDataSourceLink(title: transitousTitle, destination: transitousURL),
        JourneyDataSourceLink(title: openStreetMapTitle, destination: openStreetMapURL),
        JourneyDataSourceLink(title: operatorCoverageTitle, destination: coverageURL),
        JourneyDataSourceLink(
            title: "VIA Rail GTFS — Open Government Licence Canada 2.0",
            destination: URL(string: "https://www.viarail.ca/en/developer-resources")!
        ),
        JourneyDataSourceLink(
            title: "Amtrak route lines — U.S. DOT National Transportation Atlas Database",
            destination: URL(string: "https://geodata.bts.gov/datasets/usdot::amtrak-routes/about")!
        ),
    ]
    static let additional = [
        JourneyDataSourceLink(title: "Amtraker", destination: URL(string: "https://amtraker.com")!),
        JourneyDataSourceLink(
            title: "Datenquelle: ÖBB-Infrastruktur AG",
            destination: URL(string: "https://infrastruktur.oebb.at")!
        ),
        JourneyDataSourceLink(
            title: "Administration des transports publics / mobiliteit.lu",
            destination: URL(string: "https://data.public.lu/en/datasets/api-mobiliteit-lu/")!
        ),
        JourneyDataSourceLink(
            title: "Transport Information supplied by Translink Opendata API",
            destination: URL(string: "https://www.translink.co.uk/translinkpublictransportapi")!
        ),
        JourneyDataSourceLink(
            title: "Transwa schedule data is available free from Transperth",
            destination: URL(string: "https://www.transperth.wa.gov.au/About/Spatial-Data-Access")!
        ),
    ]

    static func linkHint(_ title: String) -> String {
        "Opens \(title) source information in the browser"
    }
}

struct JourneySourceAttribution: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case transitous
        case openStreetMap
        case feed
    }

    let kind: Kind
    let title: String
    let destination: URL?
    var id: String { "\(kind.rawValue)-\(title.lowercased())" }

    static func presentations(from backendValues: [String]) -> [Self] {
        var seen = Set<String>()
        return backendValues.compactMap { rawValue in
            guard let value = validBackendValue(rawValue) else { return nil }
            let presentation = canonicalPresentation(for: value)
            guard seen.insert(presentation.id).inserted else { return nil }
            return presentation
        }
    }

    private static func canonicalPresentation(for value: String) -> Self {
        let identity = value.lowercased()
        if identity == "srbijavoz official timetable" {
            return Self(
                kind: .feed,
                title: "Srbijavoz official timetable",
                destination: URL(string: "https://webapi1.srbvoz.rs/ekarta/")
            )
        }
        if identity == "transitous" {
            return Self(
                kind: .transitous,
                title: JourneyDataSources.transitousTitle,
                destination: JourneyDataSources.transitousURL
            )
        }
        if identity == "openstreetmap" || identity == "openstreetmap contributors" {
            return Self(
                kind: .openStreetMap,
                title: JourneyDataSources.openStreetMapContributorsTitle,
                destination: JourneyDataSources.openStreetMapURL
            )
        }
        return Self(kind: .feed, title: value, destination: JourneyDataSources.feedDirectoryURL)
    }

    private static func validBackendValue(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 120, !value.contains("://") else { return nil }
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        guard !JourneyCommerceCopyGuard.containsForbiddenCopy(value) else {
            return nil
        }
        return value
    }
}

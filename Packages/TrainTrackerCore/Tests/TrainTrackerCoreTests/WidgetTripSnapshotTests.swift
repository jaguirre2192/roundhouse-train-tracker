import Foundation
import Testing
@testable import TrainTrackerCore

@Suite struct WidgetTripSnapshotTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let newYork = TimeZone(identifier: "America/New_York")!
    private var clock: WidgetClock { WidgetClock(locale: Locale(identifier: "en_US"), deviceTimeZone: newYork) }

    // MARK: Selection

    @Test func nextTrainIsTheFirstUnfinishedByTimetable() {
        let early = train("early", departure: -120, arrival: -60, confirmedArrival: true)
        let next = train("next", departure: 30, arrival: 90)
        let later = train("later", departure: 240, arrival: 300)
        let snapshot = WidgetTripSnapshot.make(trains: [later, early, next], generatedAt: base)

        #expect(snapshot.trains.map(\.id) == ["early", "next", "later"])
        #expect(WidgetDisplay(snapshot: snapshot, at: base) == .train(next, following: later))
    }

    @Test func arrivedTrainStaysForGraceThenHandsOver() {
        let first = train("first", departure: -60, arrival: -10, confirmedArrival: true)
        let second = train("second", departure: 60, arrival: 120)
        let snapshot = WidgetTripSnapshot(generatedAt: base, trains: [first, second])

        #expect(WidgetDisplay(snapshot: snapshot, at: base) == .train(first, following: second))
        #expect(WidgetTrainPresentation(train: first, at: base, clock: clock).phase == .arrived)
        #expect(WidgetDisplay(snapshot: snapshot, at: minutes(20)) == .train(second, following: nil))
    }

    @Test func underwayVersusUpcomingAndNextStop() {
        let leg = WidgetTripSnapshot.Train(id: "t", serviceName: "Acela 2151", stops: [
            stop("NYP", departure: 0),
            stop("NWK", arrival: 15, departure: 17),
            stop("TRE", arrival: 45, departure: 46),
            stop("PHL", arrival: 80),
        ], progressEvidence: WidgetProgressEvidence(arrivalConfirmedAt: minutes(80), reportedArrivalAt: minutes(80)))
        #expect(WidgetTrainPhase(train: leg, at: minutes(-40)) == .upcoming(departureSoon: false))
        #expect(WidgetTrainPhase(train: leg, at: minutes(-30)) == .upcoming(departureSoon: true))
        #expect(WidgetTrainPhase(train: leg, at: minutes(0)) == .underway(nextStopIndex: 1))
        // A stop stays next until its departure, through its dwell.
        #expect(WidgetTrainPhase(train: leg, at: minutes(16)) == .underway(nextStopIndex: 1))
        #expect(WidgetTrainPhase(train: leg, at: minutes(17)) == .underway(nextStopIndex: 2))
        #expect(WidgetTrainPhase(train: leg, at: minutes(50)) == .underway(nextStopIndex: 3))
        #expect(WidgetTrainPhase(train: leg, at: minutes(80)) == .arrived)

        let underway = WidgetTrainPresentation(train: leg, at: minutes(20), clock: clock)
        #expect(underway.anchor == .arrives)
        #expect(underway.nextStop?.label == "TRE")
        #expect(underway.rectangularDetail == "Scheduled next TRE 3:46 · Saved")
    }

    @Test func endedWhenEveryTrainHasFinished() {
        let a = train("a", departure: -300, arrival: -240, confirmedArrival: true)
        let b = train("b", departure: -120, arrival: -60, confirmedArrival: true)
        let snapshot = WidgetTripSnapshot.make(trains: [a, b], generatedAt: base)

        #expect(snapshot.trains.map(\.id) == ["b"], "only the latest finished train is kept")
        #expect(WidgetDisplay(snapshot: snapshot, at: base) == .ended(b))
        #expect(WidgetDisplay(snapshot: .empty, at: base) == .empty)
        #expect(WidgetDisplay(snapshot: nil, at: base) == .empty)
    }

    @Test func cancelledTrainLeadsUntilItsTimetabledDepartureHasPassed() {
        let cancelled = train("x", departure: 20, arrival: 80, cancelled: true)
        let next = train("y", departure: 120, arrival: 180)
        let snapshot = WidgetTripSnapshot(generatedAt: base, trains: [cancelled, next])
        #expect(WidgetDisplay(snapshot: snapshot, at: base) == .train(cancelled, following: next))
        #expect(WidgetDisplay(snapshot: snapshot, at: minutes(51)) == .train(next, following: nil))

        let presentation = WidgetTrainPresentation(train: cancelled, at: base, clock: clock)
        #expect(presentation.statusText == "Canceled")
        #expect(presentation.platformValue == nil)
        #expect(presentation.inlineText == "NYP 3:20 · Canceled")
    }

    @Test func snapshotKeepsAtMostThreeUpcomingTrains() {
        var trains: [WidgetTripSnapshot.Train] = []
        for index in 0..<6 {
            let departure = Double(60 + index * 60)
            trains.append(train("t\(index)", departure: departure, arrival: departure + 30))
        }
        let snapshot = WidgetTripSnapshot.make(trains: trains, generatedAt: base)
        let ids: [String] = snapshot.trains.map { $0.id }
        #expect(ids == ["t0", "t1", "t2"])
    }

    // MARK: Copy

    @Test func inlineAndRectangularText() {
        let delayed = train("d", departure: 30, arrival: 90, expectedDepartureDelay: 7, platform: "7", kind: .track,
                            checked: minutes(-3), confirmedArrival: true)
        let presentation = WidgetTrainPresentation(train: delayed, at: base, clock: clock)
        // 1_800_000_000 is 3:00 AM in New York; departure 3:30, estimate 3:37.
        #expect(presentation.statusText == "7 min late")
        #expect(plain(presentation.anchorTimeText) == "3:37 AM")
        #expect(plain(presentation.struckTimetableText) == "3:30 AM")
        #expect(presentation.inlineText == "NYP 3:37 · +7 min")
        #expect(presentation.rectangularDetail == "Track 7")
        #expect(presentation.freshnessText(timeZone: newYork) == "Checked 3 min ago")

        let onTime = train("o", departure: 30, arrival: 90, expectedDepartureDelay: 2, platform: "7", kind: .track)
        let onTimePresentation = WidgetTrainPresentation(train: onTime, at: base, clock: clock)
        #expect(onTimePresentation.statusText == "On time")
        #expect(onTimePresentation.struckTimetableText == nil)
        #expect(onTimePresentation.freshnessText(timeZone: newYork) == "Not checked yet")
        #expect(onTimePresentation.rectangularDetail == "Track 7 · Saved")

        let scheduledOnly = train("s", departure: 30, arrival: 90, platform: "4", kind: .track)
        let scheduled = WidgetTrainPresentation(train: scheduledOnly, at: base, clock: clock)
        #expect(scheduled.statusText == "Timetable")
        #expect(scheduled.inlineText == "NYP 3:30 · Track 4", "punctuality is not claimed without an estimate")

        let underway = WidgetTrainPresentation(train: delayed, at: minutes(40), clock: clock)
        #expect(underway.inlineText.hasPrefix("Arr. PHL 4:37"))

        let arrived = WidgetTrainPresentation(train: delayed, at: minutes(100), clock: clock)
        #expect(arrived.inlineText == "Arrived PHL 4:37")
        #expect(arrived.statusText == "Arrived")
    }

    @Test func zoneAbbreviationOnlyWhenStationClockDiffers() {
        let paris = WidgetTripSnapshot.Train(id: "p", serviceName: "TGV", stops: [
            stop("PAR", departure: 30, zone: "Europe/Paris"),
            stop("LYS", arrival: 150, zone: "Europe/Paris"),
        ])
        let fromNewYork = WidgetTrainPresentation(train: paris, at: base, clock: clock)
        #expect(fromNewYork.anchorZone != nil)
        #expect(plain(fromNewYork.anchorTimeText) == "9:30 AM")
        #expect(fromNewYork.inlineText.hasPrefix("PAR 9:30 "))

        let uncoded = WidgetTripSnapshot.Train(id: "u", serviceName: "TGV", stops: [
            WidgetTripSnapshot.Stop(name: "Paris Gare de Lyon", timeZoneIdentifier: "America/New_York", scheduledDeparture: minutes(30)),
            WidgetTripSnapshot.Stop(name: "Lyon Part-Dieu", timeZoneIdentifier: "America/New_York", scheduledArrival: minutes(150)),
        ])
        #expect(WidgetTrainPresentation(train: uncoded, at: base, clock: clock).inlineText == "Dep. 3:30 · Timetable",
                "long station names never crowd the inline slot")

        let local = WidgetClock(locale: Locale(identifier: "en_US"), deviceTimeZone: TimeZone(identifier: "Europe/Paris")!)
        #expect(WidgetTrainPresentation(train: paris, at: base, clock: local).anchorZone == nil)
    }

    @Test func amtrakSaysTrackAndOthersSayPlatform() {
        let amtrakTrip = trip(source: "transitous", operatorName: "Amtrak", platformKind: nil)
        let amtrak = WidgetTripSnapshot.Train(trip: amtrakTrip, referenceDate: base)
        #expect(amtrak?.boarding?.platformNoun == "Track")
        #expect(amtrak.map { WidgetTrainPresentation(train: $0, at: base).platformText } == "Track 9")

        let ukTrip = trip(source: "transitous", operatorName: "Avanti West Coast", platformKind: .platform)
        let uk = WidgetTripSnapshot.Train(trip: ukTrip, referenceDate: base)
        #expect(uk.map { WidgetTrainPresentation(train: $0, at: base).platformText } == "Platform 9")

        let missing = WidgetTripSnapshot.Train(id: "m", serviceName: "X", stops: [
            stop("A", departure: 30, kind: .track), stop("B", arrival: 60, kind: .track),
        ])
        #expect(WidgetTrainPresentation(train: missing, at: base).platformText == "Track —")
    }

    @Test func builderKeepsTheSelectedLegAndDeepLink() throws {
        let built = try #require(WidgetTripSnapshot.Train(
            trip: trip(source: "amtraker", operatorName: "Amtrak", platformKind: .track),
            boardingStationID: RailIdentifier(rawValue: "us:amtrak:NWK"),
            alightingStationID: RailIdentifier(rawValue: "us:amtrak:PHL"),
            stationCodes: [RailIdentifier(rawValue: "us:amtrak:NWK"): "NWK"],
            referenceDate: base
        ))
        #expect(built.stops.map(\.name) == ["NWK", "TRE", "PHL"])
        #expect(built.boarding?.code == "NWK")
        #expect(built.alighting?.code == nil, "codes are never invented")
        let url = try #require(built.deepLinkURL)
        #expect(url.absoluteString == "traintracker://journey?trip=us:amtrak:2151&boarding=us:amtrak:NWK&alighting=us:amtrak:PHL")
    }

    @Test func timelineIncludesKnownFutureMoments() {
        let leg = train("t", departure: 40, arrival: 100, checked: minutes(-2))
        let dates = WidgetTripSnapshot(generatedAt: base, trains: [leg]).timelineDates(after: base)
        #expect(dates.contains(minutes(10)), "departure soon, 30 minutes before")
        #expect(dates.contains(minutes(40)), "departure")
        #expect(dates.contains(minutes(100)), "arrival")
        #expect(dates.contains(minutes(220)), "bounded retention does not imply confirmed arrival")
        #expect(dates.contains(minutes(-1)) == false)
        #expect(dates.contains(minutes(1)), "freshness wording ticks each minute at first")
        #expect(dates == dates.sorted())
    }

    @Test func storeRoundTripsAndSkipsUnchangedWrites() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "widget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WidgetSnapshotStore(fileURL: url)
        let snapshot = WidgetTripSnapshot(generatedAt: base, trains: [train("a", departure: 30, arrival: 60)])
        #expect(try store.save(snapshot))
        #expect(store.load() == snapshot)
        #expect(try store.save(WidgetTripSnapshot(generatedAt: minutes(5), trains: snapshot.trains)) == false)
    }

    // MARK: Helpers

    private func minutes(_ value: Double) -> Date { base.addingTimeInterval(value * 60) }

    /// ICU separates the day period with a narrow no-break space.
    private func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func stop(
        _ code: String, arrival: Double? = nil, departure: Double? = nil, zone: String? = "America/New_York",
        kind: PlatformKind? = nil
    ) -> WidgetTripSnapshot.Stop {
        WidgetTripSnapshot.Stop(
            name: code, code: code, timeZoneIdentifier: zone,
            scheduledArrival: arrival.map(minutes), scheduledDeparture: departure.map(minutes), platformKind: kind
        )
    }

    private func train(
        _ id: String, departure: Double, arrival: Double, cancelled: Bool = false,
        expectedDepartureDelay: Double? = nil, platform: String? = nil, kind: PlatformKind? = nil, checked: Date? = nil,
        confirmedArrival: Bool = false
    ) -> WidgetTripSnapshot.Train {
        WidgetTripSnapshot.Train(id: id, serviceName: "Train \(id)", stops: [
            WidgetTripSnapshot.Stop(
                name: "New York Penn", code: "NYP", timeZoneIdentifier: "America/New_York",
                scheduledDeparture: minutes(departure),
                expectedDeparture: expectedDepartureDelay.map { minutes(departure + $0) },
                platform: platform, platformKind: kind, isCancelled: cancelled
            ),
            WidgetTripSnapshot.Stop(
                name: "Philadelphia", code: "PHL", timeZoneIdentifier: "America/New_York",
                scheduledArrival: minutes(arrival),
                expectedArrival: expectedDepartureDelay.map { minutes(arrival + $0) },
                platformKind: kind, isCancelled: cancelled
            ),
        ], lastSuccessfulCheck: checked, progressEvidence: confirmedArrival ? WidgetProgressEvidence(
            arrivalConfirmedAt: minutes(arrival + (expectedDepartureDelay ?? 0)),
            reportedArrivalAt: minutes(arrival + (expectedDepartureDelay ?? 0))
        ) : nil)
    }

    private func trip(source: String, operatorName: String, platformKind: PlatformKind?) -> TrainTrip {
        func call(_ code: String, _ sequence: Int, arrival: Double?, departure: Double?) -> StopTime {
            StopTime(
                station: Station(
                    id: RailIdentifier(rawValue: "us:amtrak:\(code)"), names: [LocalizedStationName(code)],
                    location: GeoCoordinate(latitude: 0, longitude: 0), countryCode: "US"
                ),
                sequence: sequence,
                scheduledArrival: arrival.map(minutes), scheduledDeparture: departure.map(minutes),
                plannedPlatform: "9", platformKind: platformKind
            )
        }
        return TrainTrip(
            id: RailIdentifier(rawValue: "us:amtrak:2151"), source: source, serviceDate: base,
            operatorName: operatorName, product: "Acela 2151", headsign: "Washington",
            stopTimes: [
                call("NYP", 1, arrival: nil, departure: 30),
                call("NWK", 2, arrival: 45, departure: 47),
                call("TRE", 3, arrival: 75, departure: 76),
                call("PHL", 4, arrival: 110, departure: nil),
            ],
            capabilities: RealtimeCapabilities(
                hasPositions: false, hasPlatforms: true, hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop
            )
        )
    }
}

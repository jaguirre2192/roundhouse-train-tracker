#if DEBUG
  import Foundation
  import SwiftUI
  import TrainTrackerCore

  enum JourneyResultsPreviewMode: Equatable {
    case outbound
    case `return`
    case japanese
    case importedTrain

    static func resolve(arguments: [String]) -> Self? {
      if arguments.contains("-JourneyResultsPreviewImportedTrain") { return .importedTrain }
      if arguments.contains("-JourneyResultsPreviewJapanese") { return .japanese }
      if arguments.contains("-JourneyResultsPreviewReturn") { return .return }
      if arguments.contains("-JourneyResultsPreviewOutbound") { return .outbound }
      return nil
    }

    @MainActor
    func bootstrap(_ store: JourneySearchStore) async {
      guard store.phase == .editing else { return }
      if self == .importedTrain {
        // Launch with -AppStorePreview to keep backend and push disabled.
        // The existing evening TGV option must stay ahead of the morning Eurostar.
        let fixture = JourneyResultsPreviewFixture()
        guard let origin = fixture.form.origin, let destination = fixture.form.destination else { return }
        await store.prefillTicketJourney(TicketJourneySearchRequest(
          originName: origin.displayName,
          destinationName: destination.displayName,
          departureTime: ISO8601DateFormatter().string(from: fixture.form.outboundTime),
          trainNumber: "9579"
        ))
        await waitUntil { store.phase == .showingOutbound }
        return
      }
      store.searchOutbound()
      await waitUntil { store.phase == .showingOutbound }
      guard self == .return, let outbound = store.visibleOutboundOptions.first else { return }
      store.selectOutbound(outbound)
      await waitUntil { store.phase == .showingReturn }
    }

    @MainActor
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
      for _ in 0..<200 {
        if condition() { return }
        await Task.yield()
      }
    }
  }

  enum JourneyLiveRoundTripQAMode: Equatable {
    case parisAmsterdam

    static func resolve(arguments: [String]) -> Self? {
      arguments.contains("-JourneyLiveRoundTripQA") ? .parisAmsterdam : nil
    }

    func form(relativeTo now: Date = .now) -> JourneySearchFormState {
      let outbound = Self.nextDate(after: now, dayOffset: 1, hour: 8, timeZone: "Europe/Paris")
      let returnTime = Self.nextDate(
        after: now,
        dayOffset: 2,
        hour: 16,
        timeZone: "Europe/Amsterdam"
      )
      return JourneySearchFormState(
        origin: Self.parisNord,
        destination: Self.amsterdamCentraal,
        outboundTime: outbound,
        returnEnabled: true,
        returnTime: returnTime,
        maximumTransfers: 4
      )
    }

    @MainActor
    func bootstrap(_ store: JourneySearchStore) async {
      guard store.phase == .editing else { return }
      store.searchOutbound()
    }

    private static func nextDate(
      after now: Date,
      dayOffset: Int,
      hour: Int,
      timeZone identifier: String
    ) -> Date {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: identifier)!
      let start = calendar.startOfDay(for: now)
      let day = calendar.date(byAdding: .day, value: dayOffset, to: start)!
      return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    private static let parisNord = place(
      id: "rail:transitous:station:ZGUtREVMRklfMDAwMDA4NzAwMDE0H0ZSHx8",
      name: "Paris-Nord",
      country: "FR",
      timeZone: "Europe/Paris",
      latitude: 48.88089,
      longitude: 2.354931
    )

    private static let amsterdamCentraal = place(
      id: "rail:transitous:station:ZGUtREVMRklfMDAwMDA4NDAwMDU4H05MHx8",
      name: "Amsterdam Centraal",
      country: "NL",
      timeZone: "Europe/Amsterdam",
      latitude: 52.37919,
      longitude: 4.899431
    )

    private static func place(
      id: String,
      name: String,
      country: String,
      timeZone: String,
      latitude: Double,
      longitude: Double
    ) -> RailPlace {
      RailPlace(
        id: RailIdentifier(rawValue: id),
        kind: .station,
        displayName: name,
        context: timeZone,
        countryCode: country,
        timeZoneIdentifier: timeZone,
        location: GeoCoordinate(latitude: latitude, longitude: longitude),
        eligibleModes: ["highSpeedRail", "longDistanceRail", "nightRail", "regionalRail"],
        attributions: ["Transitous", "OpenStreetMap contributors"]
      )
    }
  }

  struct JourneyResultsPreviewFixture {
    let form: JourneySearchFormState
    let outboundPage: JourneySearchPage
    let returnPage: JourneySearchPage

    init() {
      let paris = Self.place(
        id: "preview:paris-nord",
        name: "Paris Gare du Nord",
        context: "Paris, France",
        country: "FR",
        timeZone: "Europe/Paris"
      )
      let amsterdam = Self.place(
        id: "preview:amsterdam-centraal",
        name: "Amsterdam Centraal",
        context: "Amsterdam, Netherlands",
        country: "NL",
        timeZone: "Europe/Amsterdam"
      )
      let parisEst = Self.place(
        id: "preview:paris-est",
        name: "Paris Gare de l'Est",
        context: "Paris, France",
        country: "FR",
        timeZone: "Europe/Paris"
      )
      let stuttgart = Self.place(
        id: "preview:stuttgart-hbf",
        name: "Stuttgart Hauptbahnhof",
        context: "Stuttgart, Germany",
        country: "DE",
        timeZone: "Europe/Berlin"
      )
      let directStart = Self.date("2026-07-24T06:25:00Z")
      let directEnd = Self.date("2026-07-24T10:14:00Z")
      let directRail = Self.rail(
        id: "preview-eurostar",
        operatorName: "Eurostar",
        product: "Eurostar",
        trainNumber: "9315",
        trainName: "Eurostar 9315",
        from: Self.call(
          place: paris,
          scheduledDeparture: directStart,
          expectedDeparture: Self.date("2026-07-24T06:28:00Z"),
          plannedPlatform: "7",
          expectedPlatform: "8"
        ),
        to: Self.call(
          place: amsterdam,
          scheduledArrival: directEnd,
          expectedArrival: Self.date("2026-07-24T10:17:00Z"),
          plannedPlatform: "15b",
          expectedPlatform: "15b"
        ),
        isRealtime: true,
        isTrackable: true
      )
      let direct = Self.option(
        id: "preview-direct",
        start: directStart,
        end: directEnd,
        transferCount: 0,
        segments: [.rail(directRail)],
        badges: [.direct, .fastest, .fewestChanges],
        trackable: 1,
        total: 1,
        realtime: true
      )

      let overnightStart = Self.date("2026-07-24T19:55:00Z")
      let transferTime = Self.date("2026-07-24T21:47:00Z")
      let overnightEnd = Self.date("2026-07-25T06:19:00Z")
      let tgv = Self.rail(
        id: "preview-tgv",
        operatorName: "SNCF",
        product: "TGV INOUI",
        trainNumber: "9579",
        trainName: "TGV 9579",
        from: Self.call(place: parisEst, scheduledDeparture: overnightStart, plannedPlatform: "6"),
        to: Self.call(place: stuttgart, scheduledArrival: transferTime, plannedPlatform: "9"),
        isRealtime: false,
        isTrackable: true
      )
      let walk = WalkJourneySegment(
        id: "preview-walk",
        from: stuttgart,
        to: stuttgart,
        duration: 600,
        distance: 450,
        isStationChange: true
      )
      let nightjet = Self.rail(
        id: "preview-nightjet",
        operatorName: "ÖBB",
        product: "Nightjet",
        trainNumber: "NJ 237",
        trainName: "Nightjet 237",
        from: Self.call(
          place: stuttgart,
          scheduledDeparture: Self.date("2026-07-24T22:11:00Z"),
          expectedDeparture: Self.date("2026-07-24T22:26:00Z"),
          plannedPlatform: "8",
          expectedPlatform: "10",
          isCancelled: true
        ),
        to: Self.call(place: amsterdam, scheduledArrival: overnightEnd, isCancelled: true),
        isRealtime: true,
        isTrackable: false,
        isCancelled: true,
        untrackableReason: "No stable train identity"
      )
      let overnight = Self.option(
        id: "preview-overnight",
        start: overnightStart,
        end: overnightEnd,
        transferCount: 1,
        segments: [.rail(tgv), .walk(walk), .rail(nightjet)],
        badges: [],
        trackable: 1,
        total: 2,
        realtime: true
      )

      let returnStart = Self.date("2026-07-28T07:15:00Z")
      let returnEnd = Self.date("2026-07-28T11:02:00Z")
      let returnRail = Self.rail(
        id: "preview-return-eurostar",
        operatorName: "Eurostar",
        product: "Eurostar",
        trainNumber: "9328",
        trainName: "Eurostar 9328",
        from: Self.call(place: amsterdam, scheduledDeparture: returnStart, plannedPlatform: "15a"),
        to: Self.call(place: paris, scheduledArrival: returnEnd, plannedPlatform: "8"),
        isRealtime: false,
        isTrackable: true
      )
      let returnOption = Self.option(
        id: "preview-return",
        start: returnStart,
        end: returnEnd,
        transferCount: 0,
        segments: [.rail(returnRail)],
        badges: [.direct, .fastest, .fewestChanges],
        trackable: 1,
        total: 1,
        realtime: false
      )

      form = JourneySearchFormState(
        origin: paris,
        destination: amsterdam,
        outboundTime: directStart,
        returnEnabled: true,
        returnTime: returnStart,
        directOnly: false,
        maximumTransfers: 4
      )
      outboundPage = Self.page(options: [overnight, direct])
      returnPage = Self.page(options: [returnOption])
    }

    private static func page(options: [JourneyOption]) -> JourneySearchPage {
      JourneySearchPage(
        generatedAt: date("2026-07-21T19:00:00Z"),
        expiresAt: date("2026-07-21T19:10:00Z"),
        options: options,
        previousCursor: "preview.previous.signed",
        nextCursor: "preview.next.signed",
        warnings: [],
        attributions: ["Transitous", "OpenStreetMap contributors"]
      )
    }

    private static func option(
      id: String,
      start: Date,
      end: Date,
      transferCount: Int,
      segments: [JourneySegment],
      badges: [JourneyBadge],
      trackable: Int,
      total: Int,
      realtime: Bool
    ) -> JourneyOption {
      JourneyOption(
        id: id,
        fingerprint: "preview-fingerprint-\(id)",
        startTime: start,
        endTime: end,
        duration: end.timeIntervalSince(start),
        transferCount: transferCount,
        segments: segments,
        badges: badges,
        trackability: JourneyTrackability(
          trackableRailSegments: trackable,
          totalRailSegments: total
        ),
        realtimeFreshness: realtime ? date("2026-07-21T18:59:30Z") : nil,
        attributions: ["Transitous", "OpenStreetMap contributors"],
        trackingToken: "preview.signed.\(id)"
      )
    }

    private static func rail(
      id: String,
      operatorName: String,
      product: String,
      trainNumber: String,
      trainName: String,
      from: JourneyCall,
      to: JourneyCall,
      isRealtime: Bool,
      isTrackable: Bool,
      isCancelled: Bool = false,
      untrackableReason: String? = nil
    ) -> RailJourneySegment {
      RailJourneySegment(
        id: id,
        tripID: isTrackable ? RailIdentifier(rawValue: "preview:trip:\(id)") : nil,
        serviceDate: from.scheduledDeparture ?? to.scheduledArrival ?? date("2026-07-24T00:00:00Z"),
        operatorName: operatorName,
        product: product,
        trainNumber: trainNumber,
        trainName: trainName,
        from: from,
        to: to,
        intermediateCalls: [],
        isCancelled: isCancelled,
        isRealtime: isRealtime,
        isTrackable: isTrackable,
        untrackableReason: untrackableReason
      )
    }

    private static func call(
      place: RailPlace,
      scheduledArrival: Date? = nil,
      scheduledDeparture: Date? = nil,
      expectedArrival: Date? = nil,
      expectedDeparture: Date? = nil,
      plannedPlatform: String? = nil,
      expectedPlatform: String? = nil,
      isCancelled: Bool = false
    ) -> JourneyCall {
      JourneyCall(
        place: place,
        city: nil,
        scheduledArrival: scheduledArrival,
        scheduledDeparture: scheduledDeparture,
        expectedArrival: expectedArrival,
        expectedDeparture: expectedDeparture,
        plannedPlatform: plannedPlatform,
        expectedPlatform: expectedPlatform,
        isCancelled: isCancelled
      )
    }

    private static func place(
      id: String,
      name: String,
      context: String,
      country: String,
      timeZone: String
    ) -> RailPlace {
      RailPlace(
        id: RailIdentifier(rawValue: id),
        kind: .station,
        displayName: name,
        context: context,
        countryCode: country,
        timeZoneIdentifier: timeZone,
        location: GeoCoordinate(latitude: 0, longitude: 0),
        eligibleModes: ["highSpeedRail", "longDistanceRail"],
        attributions: ["Transitous", "OpenStreetMap contributors"]
      )
    }

    private static func date(_ value: String) -> Date {
      ISO8601DateFormatter().date(from: value)!
    }
  }

  actor JourneyResultsPreviewClient: JourneySearching {
    private let fixture: JourneyResultsPreviewFixture
    private let reviewMode: JourneyReviewPreviewMode?

    init(
      fixture: JourneyResultsPreviewFixture,
      reviewMode: JourneyReviewPreviewMode? = nil
    ) {
      self.fixture = fixture
      self.reviewMode = reviewMode
    }

    func searchPlaces(query: String, limit: Int) async throws -> [RailPlace] {
      [fixture.form.origin, fixture.form.destination].compactMap { $0 }
    }

    func searchJourneys(criteria: JourneySearchCriteria) async throws -> JourneySearchPage {
      criteria.originID == fixture.form.origin?.id ? fixture.outboundPage : fixture.returnPage
    }

    func resolvePlan(trackingTokens: [String]) async throws -> JourneyPlanResolution {
      reviewMode?.resolution(fixture: fixture)
        ?? JourneyPlanResolution(directions: [])
    }
  }
#endif

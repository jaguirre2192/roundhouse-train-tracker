import Foundation
import TrainTrackerCore

struct JourneySelectionSnapshot: Sendable {
    let draftID: UUID
    let origin: RailPlace
    let destination: RailPlace
    let outbound: JourneyOption
    let returnOption: JourneyOption?
    let outboundCriteria: JourneySearchCriteria
    let returnCriteria: JourneySearchCriteria?

    init?(
        draftID: UUID,
        form: JourneySearchFormState,
        outbound: JourneyOption?,
        returnOption: JourneyOption?,
        continuingAsOneWay: Bool,
        outboundCriteria: JourneySearchCriteria?,
        returnCriteria: JourneySearchCriteria?
    ) {
        guard let origin = form.origin,
              let destination = form.destination,
              let outbound,
              let outboundCriteria else { return nil }
        let includedReturn = form.returnEnabled && !continuingAsOneWay ? returnOption : nil
        if form.returnEnabled && !continuingAsOneWay && includedReturn == nil { return nil }
        self.draftID = draftID
        self.origin = origin
        self.destination = destination
        self.outbound = outbound
        self.returnOption = includedReturn
        self.outboundCriteria = outboundCriteria
        self.returnCriteria = includedReturn == nil ? nil : returnCriteria
    }

    var draft: JourneyPlanDraft {
        JourneyPlanDraft(
            id: draftID,
            origin: origin,
            destination: destination,
            outbound: outbound,
            returnOption: returnOption
        )
    }

    var trackingTokens: [String] {
        [outbound.trackingToken] + [returnOption?.trackingToken].compactMap { $0 }
    }
}

enum JourneySelectionRecoveryOutcome: Sendable {
    case resolvedWithoutRefresh(JourneyPlanResolution)
    case resolved(
        outboundPage: JourneySearchPage,
        returnPage: JourneySearchPage?,
        outbound: JourneyOption,
        returnOption: JourneyOption?,
        resolution: JourneyPlanResolution
    )
    case outboundNeedsReview(page: JourneySearchPage)
    case returnNeedsReview(
        outboundPage: JourneySearchPage,
        outbound: JourneyOption,
        returnPage: JourneySearchPage
    )
}

enum JourneySelectionRecovery {
    static func resolve(
        client: any JourneySearching,
        snapshot: JourneySelectionSnapshot
    ) async throws -> JourneySelectionRecoveryOutcome {
        do {
            return .resolvedWithoutRefresh(
                try await client.resolvePlan(trackingTokens: snapshot.trackingTokens)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard isTrackingTokenExpired(error) else { throw error }
            return try await recover(client: client, snapshot: snapshot)
        }
    }

    static func recover(
        client: any JourneySearching,
        snapshot: JourneySelectionSnapshot
    ) async throws -> JourneySelectionRecoveryOutcome {
        let outboundPage = try await client.searchJourneys(criteria: snapshot.outboundCriteria)
        guard let outbound = matchingOption(snapshot.outbound, in: outboundPage) else {
            return .outboundNeedsReview(page: outboundPage)
        }

        var returnPage: JourneySearchPage?
        var returnOption: JourneyOption?
        if let selectedReturn = snapshot.returnOption,
           let criteria = snapshot.returnCriteria {
            let searchedPage = try await client.searchJourneys(criteria: criteria)
            let validPage = JourneySearchPolicy.filterReturnPage(
                searchedPage,
                after: outbound
            )
            guard let matchedReturn = matchingOption(selectedReturn, in: validPage) else {
                return .returnNeedsReview(
                    outboundPage: outboundPage,
                    outbound: outbound,
                    returnPage: validPage
                )
            }
            returnPage = validPage
            returnOption = matchedReturn
        }

        let tokens = [outbound.trackingToken] + [returnOption?.trackingToken].compactMap { $0 }
        let resolution = try await client.resolvePlan(trackingTokens: tokens)
        return .resolved(
            outboundPage: outboundPage,
            returnPage: returnPage,
            outbound: outbound,
            returnOption: returnOption,
            resolution: resolution
        )
    }

    private static func matchingOption(
        _ selected: JourneyOption,
        in page: JourneySearchPage
    ) -> JourneyOption? {
        guard let refreshed = page.options.first(where: { $0.fingerprint == selected.fingerprint }) else {
            return nil
        }
        return scheduleSignature(refreshed) == scheduleSignature(selected) ? refreshed : nil
    }

    private static func scheduleSignature(_ option: JourneyOption) -> OptionScheduleSignature {
        let endpointDates = option.effectiveEndpointDates
        return OptionScheduleSignature(
            start: endpointDates.departure,
            end: endpointDates.arrival,
            segments: option.segments.map(segmentSignature)
        )
    }

    private static func segmentSignature(_ segment: JourneySegment) -> SegmentScheduleSignature {
        switch segment {
        case let .rail(rail):
            return .rail(
                tripID: rail.tripID,
                serviceDate: rail.serviceDate,
                operatorName: rail.operatorName,
                product: rail.product,
                trainNumber: rail.trainNumber,
                trainName: rail.trainName,
                from: callSignature(rail.from),
                to: callSignature(rail.to),
                intermediateCalls: rail.intermediateCalls.map(callSignature),
                isCancelled: rail.isCancelled
            )
        case let .walk(walk):
            return .walk(
                fromID: walk.from.id,
                destinationID: walk.to.id,
                duration: walk.duration,
                distance: walk.distance
            )
        }
    }

    private static func callSignature(_ call: JourneyCall) -> CallScheduleSignature {
        CallScheduleSignature(
            placeID: call.place.id,
            scheduledArrival: call.scheduledArrival,
            scheduledDeparture: call.scheduledDeparture,
            expectedArrival: call.expectedArrival,
            expectedDeparture: call.expectedDeparture,
            isCancelled: call.isCancelled
        )
    }

    static func isTrackingTokenExpired(_ error: Error) -> Bool {
        error as? JourneySearchClient.ClientError == .trackingTokenExpired
    }
}

private struct OptionScheduleSignature: Equatable {
    let start: Date
    let end: Date
    let segments: [SegmentScheduleSignature]
}

private enum SegmentScheduleSignature: Equatable {
    case rail(
        tripID: RailIdentifier?,
        serviceDate: Date,
        operatorName: String,
        product: String,
        trainNumber: String?,
        trainName: String?,
        from: CallScheduleSignature,
        to: CallScheduleSignature,
        intermediateCalls: [CallScheduleSignature],
        isCancelled: Bool
    )
    case walk(
        fromID: RailIdentifier,
        destinationID: RailIdentifier,
        duration: TimeInterval,
        distance: Double?
    )
}

private struct CallScheduleSignature: Equatable {
    let placeID: RailIdentifier
    let scheduledArrival: Date?
    let scheduledDeparture: Date?
    let expectedArrival: Date?
    let expectedDeparture: Date?
    let isCancelled: Bool
}

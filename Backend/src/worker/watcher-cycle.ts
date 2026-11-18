import { carryForwardRecoveryPosition } from "../domain/trip-watch-recovery.js";
import { carryForwardPlatforms } from "../domain/platform-continuity.js";
export { carryForwardPlatforms } from "../domain/platform-continuity.js";
import { APNsError, pushHasExpired, type PushMessage, type PushSender } from "../apns/transport.js";
import type {
  ClaimedTrip,
  StoredSubscription,
  TargetedEvent,
  WatcherPersistence,
} from "./watcher-persistence.js";
import { hasFastPlatformCountry, pollIntervalSeconds } from "../domain/cadence.js";
import { diffSnapshots, type MaterialEvent } from "../domain/events.js";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import { ProviderRegistry } from "../providers/provider.js";

export interface WatcherLogger {
  info(data: object, message?: string): void;
  error(data: object, message?: string): void;
}

export interface WatcherTickReport {
  tripsClaimed: number;
  tripsPolled: number;
  providerFailures: number;
  eventsCreated: number;
  pushesClaimed: number;
  pushesDelivered: number;
  pushFailures: number;
}

interface PollResult {
  succeeded: boolean;
  eventCount: number;
}

function sequence(snapshot: TripSnapshot, stationId: string): number | null {
  return snapshot.stops.find((stop) => stop.stationId === stationId)?.sequence ?? null;
}

function eventIsWithinJourney(event: MaterialEvent, subscription: StoredSubscription, snapshot: TripSnapshot): boolean {
  if (event.stopId === null) return true;
  const eventSequence = sequence(snapshot, event.stopId);
  const boarding = sequence(snapshot, subscription.boardingStationId);
  const alighting = sequence(snapshot, subscription.alightingStationId);
  if (eventSequence === null || boarding === null || alighting === null) return true;
  return eventSequence >= Math.min(boarding, alighting) && eventSequence <= Math.max(boarding, alighting);
}

const collapsedKinds = new Set<MaterialEvent["kind"]>(["delay-threshold", "cancellation"]);

// One delay or cancellation usually applies to every remaining stop. Send only the
// earliest affected stop on the rider's journey instead of one push per stop.
export function collapseTripWideEvents(events: MaterialEvent[]): MaterialEvent[] {
  const seen = new Set<MaterialEvent["kind"]>();
  return events.filter((event) => {
    if (!collapsedKinds.has(event.kind)) return true;
    if (seen.has(event.kind)) return false;
    seen.add(event.kind);
    return true;
  });
}

function hasUpcomingPlatform(snapshot: TripSnapshot): boolean {
  return snapshot.stops.some((stop: StopSnapshot) =>
    !stop.passed && (stop.expectedPlatform ?? stop.plannedPlatform) !== null
  );
}

export class WatcherCycle {
  constructor(
    private readonly repository: WatcherPersistence,
    private readonly providers: ProviderRegistry,
    private readonly pushSender: PushSender,
    private readonly logger: WatcherLogger,
  ) {}

  async tick(): Promise<WatcherTickReport> {
    const trips = await this.repository.claimDueTrips();
    const pollResults: PollResult[] = [];
    for (const trip of trips) pollResults.push(await this.pollTrip(trip));
    const pushReport = await this.deliverOutbox();

    return {
      tripsClaimed: trips.length,
      tripsPolled: pollResults.filter((result) => result.succeeded).length,
      providerFailures: pollResults.filter((result) => !result.succeeded).length,
      eventsCreated: pollResults.reduce((total, result) => total + result.eventCount, 0),
      ...pushReport,
    };
  }

  private async pollTrip(trip: ClaimedTrip): Promise<PollResult> {
    try {
      const snapshot = carryForwardRecoveryPosition(trip.latestSnapshot,
        carryForwardPlatforms(trip.latestSnapshot, await this.providers.fetchTrip(trip)));
      const subscriptions = await this.repository.subscriptions(trip.id);
      const targetedEvents: TargetedEvent[] = subscriptions.flatMap((subscription) =>
        collapseTripWideEvents(
          diffSnapshots(trip.latestSnapshot, snapshot, subscription.preferences)
            .filter((event) => eventIsWithinJourney(event, subscription, snapshot)),
        ).map((event) => ({ installationId: subscription.installationId, event })),
      );
      const lane = hasUpcomingPlatform(snapshot) || hasFastPlatformCountry(snapshot)
        ? "platform"
        : "full-trip";
      const interval = pollIntervalSeconds(trip.source, lane, snapshot);
      await this.repository.recordSuccess(trip.id, snapshot, interval, targetedEvents);
      this.logger.info({ tripId: trip.id, events: targetedEvents.length, nextPollSeconds: interval }, "trip polled");
      return { succeeded: true, eventCount: targetedEvents.length };
    } catch (error) {
      await this.repository.recordFailure(trip.id, error);
      this.logger.error({ tripId: trip.id, error }, "trip poll failed");
      return { succeeded: false, eventCount: 0 };
    }
  }

  private async deliverOutbox(): Promise<Pick<
    WatcherTickReport,
    "pushesClaimed" | "pushesDelivered" | "pushFailures"
  >> {
    const messages = await this.repository.claimOutbox();
    const results = await Promise.all(messages.map(async (message) => {
      const push: PushMessage = {
        token: message.token,
        environment: message.environment,
        platform: message.platform,
        event: message.payload,
        createdAt: message.createdAt,
      };
      // Never hand APNs an alert whose window has already closed; a platform
      // change from hours ago is worse than no alert.
      if (pushHasExpired(push)) {
        await this.repository.markDeliveryFailed(message.id, new Error("Push expired before delivery"), true);
        this.logger.info({ outboxId: message.id }, "push expired before delivery");
        return false;
      }
      try {
        await this.pushSender.send(push);
        await this.repository.markDelivered(message.id);
        return true;
      } catch (error) {
        const invalidDevice = error instanceof APNsError && error.invalidatesDevice;
        const permanent = error instanceof APNsError && error.permanent;
        if (invalidDevice) await this.repository.retireDevice(message.token);
        await this.repository.markDeliveryFailed(message.id, error, permanent);
        this.logger.error({ outboxId: message.id, invalidDevice, permanent, error }, "push delivery failed");
        return false;
      }
    }));

    return {
      pushesClaimed: messages.length,
      pushesDelivered: results.filter(Boolean).length,
      pushFailures: results.filter((succeeded) => !succeeded).length,
    };
  }
}

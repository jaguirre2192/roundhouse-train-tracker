import type { MaterialEvent } from "../domain/events.js";
import type {
  CanonicalTripReference,
  PushPreferences,
  TripSnapshot,
} from "../domain/snapshot.js";

export interface DeviceRegistration {
  installationId: string;
  token: string;
  environment: "sandbox" | "production";
  platform: "ios" | "macos";
}

export interface SubscriptionInput {
  installationId: string;
  trip: CanonicalTripReference;
  boardingStationId: string;
  alightingStationId: string;
  watchFrom: string;
  preferences: PushPreferences;
}

export interface StoredSubscription {
  installationId: string;
  boardingStationId: string;
  alightingStationId: string;
  preferences: PushPreferences;
}

export interface ClaimedTrip extends CanonicalTripReference {
  latestSnapshot: TripSnapshot | null;
}

export interface OutboxMessage {
  id: string;
  token: string;
  environment: "sandbox" | "production";
  platform: "ios" | "macos";
  payload: MaterialEvent;
  /// Epoch milliseconds when the outbox row was created.
  createdAt: number;
}

export interface TargetedEvent {
  installationId: string;
  event: MaterialEvent;
}

export interface WatcherPersistence {
  claimDueTrips(limit?: number): Promise<ClaimedTrip[]>;
  subscriptions(tripId: string): Promise<StoredSubscription[]>;
  recordSuccess(
    tripId: string,
    snapshot: TripSnapshot,
    nextPollSeconds: number,
    targetedEvents: TargetedEvent[],
  ): Promise<void>;
  recordFailure(tripId: string, error: unknown): Promise<void>;
  claimOutbox(limit?: number): Promise<OutboxMessage[]>;
  markDelivered(id: string): Promise<void>;
  /// Retries transient failures with backoff; a permanent failure, an exhausted
  /// attempt budget, or an alert past its useful age marks the row failed.
  markDeliveryFailed(id: string, error: unknown, permanent: boolean): Promise<void>;
  /// Deactivates the device and fails every undelivered row for its installation,
  /// so a later re-registration cannot replay a stale backlog.
  retireDevice(token: string): Promise<void>;
}

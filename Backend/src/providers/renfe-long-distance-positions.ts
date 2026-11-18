import type { TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import { renfeInstant, renfeLongDistanceUpdatesURL, renfeLongDistanceVehicleURL,
  type RenfeFeed, type RenfeVehicleEntity } from "./renfe-realtime-models.js";
import type { VerifiedRenfeUpdate } from "./renfe-long-distance-timing.js";

type Coordinate = { latitude: number; longitude: number };
interface Movement { position: Coordinate; generation: number; published: number; changedAt: number | null }

function distance(a: Coordinate, b: Coordinate): number {
  const radians = Math.PI / 180;
  const dLat = (b.latitude - a.latitude) * radians;
  const dLon = (b.longitude - a.longitude) * radians;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.latitude * radians)
    * Math.cos(b.latitude * radians) * Math.sin(dLon / 2) ** 2;
  return 6_371_000 * 2 * Math.asin(Math.min(1, Math.sqrt(h)));
}

function coordinate(value: Coordinate | null | undefined): Coordinate | null {
  return value != null && Number.isFinite(value.latitude) && Number.isFinite(value.longitude)
    && Math.abs(value.latitude) <= 90 && Math.abs(value.longitude) <= 180 ? value : null;
}

/** This is only a rejection test for real coordinates, never a source of coordinates. */
function timetablePosition(snapshot: TripSnapshot, at: number, delay: number): Coordinate | null {
  const calls = snapshot.stops.map((stop) => ({
    position: coordinate(stop.latitude == null || stop.longitude == null ? null
      : { latitude: stop.latitude, longitude: stop.longitude }),
    arrival: Date.parse(stop.scheduledArrival ?? stop.scheduledDeparture ?? "") + delay * 1_000,
    departure: Date.parse(stop.scheduledDeparture ?? stop.scheduledArrival ?? "") + delay * 1_000,
  }));
  if (calls.length < 2 || calls.some((call) => call.position === null
    || !Number.isFinite(call.arrival) || !Number.isFinite(call.departure))) return null;
  if (at <= calls[0]!.departure) return calls[0]!.position;
  for (let index = 1; index < calls.length; index += 1) {
    const previous = calls[index - 1]!, current = calls[index]!;
    if (at >= current.arrival && at <= current.departure) return current.position;
    if (at < current.arrival && current.arrival > previous.departure) {
      const fraction = Math.max(0, Math.min(1, (at - previous.departure) / (current.arrival - previous.departure)));
      return { latitude: previous.position!.latitude + fraction * (current.position!.latitude - previous.position!.latitude),
        longitude: previous.position!.longitude + fraction * (current.position!.longitude - previous.position!.longitude) };
    }
  }
  return calls.at(-1)!.position;
}

function withinRun(snapshot: TripSnapshot, at: number, delay: number): boolean {
  const times = snapshot.stops.flatMap((stop) => [stop.scheduledArrival, stop.scheduledDeparture])
    .filter((time): time is string => time !== null).map((time) => Date.parse(time) + delay * 1_000);
  return times.length > 1 && times.every(Number.isFinite)
    && at >= Math.min(...times) - 5 * 60_000 && at <= Math.max(...times) + 5 * 60_000;
}

/** Recover only the measured moving vehicles supported by independent publication,
 * progression and timetable evidence. Never relabel the broken header as reported UTC. */
export class RenfeLongDistancePositions {
  private readonly movements = new Map<string, Movement>();

  positions(
    feed: RenfeFeed<RenfeVehicleEntity>, selected: VerifiedRenfeUpdate | null,
    snapshot: TripSnapshot, now: Date,
  ): VehiclePositionSnapshot[] {
    const key = `${snapshot.serviceDate}:${selected?.update.trip.tripId ?? snapshot.nativeId}`;
    const reject = (): VehiclePositionSnapshot[] => { this.movements.delete(key); return []; };
    if (selected === null || selected.cancelled || selected.delay === null) return reject();
    const header = renfeInstant(feed.header.timestamp)?.getTime();
    if (header === undefined) return reject();
    const nowMs = now.getTime();
    if (nowMs - selected.observedAt.getTime() > 120_000 || selected.observedAt.getTime() > nowMs + 30_000) return reject();
    const normalClock = nowMs - header <= 120_000 && header <= nowMs + 30_000;
    let published = header;
    let offset = 0;
    if (!normalClock) {
      const metadata = feed.transport, companion = selected.feed.transport;
      const lastModified = metadata?.lastModified;
      const tripHeader = renfeInstant(selected.feed.header.timestamp)?.getTime();
      if (metadata?.url !== renfeLongDistanceVehicleURL || companion?.url !== renfeLongDistanceUpdatesURL
        || lastModified == null || companion.lastModified == null || tripHeader === undefined
        || nowMs - lastModified > 120_000 || lastModified > nowMs + 30_000
        || Math.abs(lastModified - companion.lastModified) > 30_000
        || Math.abs(lastModified - tripHeader) > 30_000) return reject();
      offset = tripHeader - header;
      if (![3_600_000, 7_200_000].some((expected) => Math.abs(offset - expected) <= 2_000)) return reject();
      published = lastModified;
    }
    const matches = feed.entity.flatMap(({ vehicle }) => vehicle?.trip.tripId === selected.update.trip.tripId ? [vehicle] : []);
    if (matches.length !== 1) return reject();
    const vehicle = matches[0]!;
    if (![undefined, null, "SCHEDULED"].includes(vehicle.trip.scheduleRelationship?.toUpperCase())) return reject();
    if (vehicle.trip.startDate != null
      && vehicle.trip.startDate.replaceAll("-", "") !== snapshot.serviceDate.replaceAll("-", "")) return reject();
    const position = vehicle.position?.latitude == null || vehicle.position.longitude == null ? null
      : coordinate({ latitude: vehicle.position.latitude, longitude: vehicle.position.longitude });
    if (position === null || !withinRun(snapshot, published, selected.delay)) return reject();
    const current = timetablePosition(snapshot, published, selected.delay);
    if (current === null || distance(position, current) > 25_000) return reject();
    let asOf = vehicle.timestamp == null ? published : renfeInstant(vehicle.timestamp)?.getTime();
    // A present but stale/invalid vehicle measurement is never shifted or replaced.
    if (asOf === undefined || nowMs - asOf > 180_000 || asOf > nowMs + 30_000) return reject();
    if (!normalClock) {
      const old = timetablePosition(snapshot, published - offset, selected.delay);
      if (old === null) return reject();
      const currentDistance = distance(position, current);
      // Fail closed on the unexplained tail and terminal/dwell ambiguity. This tolerance
      // allows curved lines without accepting the competing hour-old hypothesis.
      if (currentDistance > 25_000 || distance(position, old) < currentDistance + 20_000) return reject();
    }
    // A fixed feed header still isn't an individual measurement timestamp.
    if (vehicle.timestamp == null) {
      const changedAt = this.observe(key, position, header, published);
      if (changedAt === null || nowMs - changedAt > 180_000) return [];
      asOf = changedAt;
    } else {
      this.movements.delete(key);
    }
    const bearing = vehicle.position?.bearing;
    return [{ ...position, heading: bearing != null && Number.isFinite(bearing) ? bearing : null,
      source: "real", confidence: normalClock ? 0.9 : 0.7, asOf: new Date(asOf).toISOString(),
      provider: "Renfe GTFS-RT",
      ...(normalClock || vehicle.timestamp != null ? {} : { timestampBasis: "feed-publication-and-movement" as const,
        providerReportedAt: new Date(header).toISOString() }),
    }];
  }

  private observe(key: string, position: Coordinate, header: number, published: number): number | null {
    // Only individually validated records enter this cache. Rejected cancellation,
    // date, timestamp or geometry evidence must never become a later movement proof.
    const old = this.movements.get(key);
    if (old?.generation === header && old.published === published) {
      if (old.position.latitude === position.latitude && old.position.longitude === position.longitude) return old.changedAt;
      this.movements.delete(key);
      return null;
    }
    const elapsed = old === undefined ? 0 : published - old.published;
    const advanced = old !== undefined && elapsed >= 10_000 && elapsed <= 180_000
      && header > old.generation && Math.abs((header - old.generation) - elapsed) <= 2_000;
    const meters = old === undefined ? 0 : distance(position, old.position);
    const moved = advanced && meters >= 30 && meters / (elapsed / 1_000) <= 120;
    const changedAt = moved ? published : advanced && meters < 30 ? old?.changedAt ?? null : null;
    this.movements.set(key, { position, generation: header, published, changedAt });
    for (const [id, value] of this.movements) if (published - value.published > 180_000) this.movements.delete(id);
    while (this.movements.size > 1_024) this.movements.delete(this.movements.keys().next().value!);
    return changedAt;
  }
}

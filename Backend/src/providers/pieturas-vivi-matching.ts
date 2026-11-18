import type { transit_realtime } from "gtfs-realtime-bindings";
import type { TripSnapshot } from "../domain/snapshot.js";

/** The same published trip ID, dated journey and complete timetable must agree. */
export function matchedViviUpdate(snapshot: TripSnapshot, feed: transit_realtime.IFeedMessage): transit_realtime.ITripUpdate | null {
  if (snapshot.source !== "transitous" || !/^\d{4}-\d{2}-\d{2}$/u.test(snapshot.serviceDate)) return null;
  const native = snapshot.nativeId.match(/^(\d{8})_(\d{2}:\d{2})_lv-pieturas_(pv-\d+)$/u);
  const date = snapshot.serviceDate.replaceAll("-", ""), serviceTime = Date.parse(`${snapshot.serviceDate}T00:00:00Z`);
  if (!Number.isFinite(serviceTime) || new Date(serviceTime).toISOString().slice(0, 10) !== snapshot.serviceDate) return null;
  if (native?.[1] !== date || snapshot.stops.length < 2 || snapshot.stops.some((stop) => stop.countryCode !== "LV")) return null;
  const candidates = (feed.entity ?? []).flatMap(({ tripUpdate }) => tripUpdate?.trip.tripId === native[3]
    && tripUpdate?.trip.startDate === date ? [tripUpdate] : []);
  if (candidates.length !== 1) return null;
  const update = candidates[0]!, calls = update.stopTimeUpdate ?? [];
  if (calls.length !== snapshot.stops.length || calls.length > 150 || (update.trip.scheduleRelationship ?? 0) !== 0) return null;
  const sequence = new Set<number>();
  const equalTime = (event: transit_realtime.TripUpdate.IStopTimeEvent | null | undefined, scheduled: string | null): boolean => {
    if (scheduled === null) return true;
    if (!event || !Object.hasOwn(event, "time") || !Object.hasOwn(event, "delay")) return false;
    const absolute = Number(event.time), delay = Number(event.delay), planned = Date.parse(scheduled);
    return Number.isFinite(absolute) && absolute > 0 && Number.isFinite(delay) && Number.isFinite(planned)
      && (absolute - delay) * 1_000 === planned;
  };
  for (let index = 0; index < calls.length; index += 1) {
    const call = calls[index]!, stop = snapshot.stops[index]!;
    if (call.stopId !== stop.stationId.replace(/^eu:transitous:lv-pieturas_/u, "")
      || !Object.hasOwn(call, "stopSequence") || !Number.isInteger(call.stopSequence) || call.stopSequence! < 0 || sequence.has(call.stopSequence!)
      || (index > 0 && call.stopSequence! <= calls[index - 1]!.stopSequence!)
      || (call.scheduleRelationship ?? 0) !== 0 || stop.cancelled
      || !equalTime(call.arrival, stop.scheduledArrival) || !equalTime(call.departure, stop.scheduledDeparture)
      || (stop.scheduledArrival === null && stop.scheduledDeparture === null)) return null;
    sequence.add(call.stopSequence!);
  }
  const firstDeparture = snapshot.stops[0]!.scheduledDeparture;
  if (firstDeparture === null) return null;
  const parts = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/Riga", hourCycle: "h23", hour: "2-digit", minute: "2-digit" })
    .formatToParts(new Date(firstDeparture));
  return `${parts.find((part) => part.type === "hour")?.value}:${parts.find((part) => part.type === "minute")?.value}` === native[2] ? update : null;
}

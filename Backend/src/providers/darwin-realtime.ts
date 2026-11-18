import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import { nearestZonedClockTime } from "./zoned-time.js";

const sourceName = "National Rail Darwin";
const serviceDateFormatter = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/London",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

interface XMLAttributes { [key: string]: string | undefined }

export interface DarwinLocationState {
  tpl: string;
  expectedArrival?: string;
  expectedDeparture?: string;
  actualArrival?: string;
  actualDeparture?: string;
  actualPass?: string;
  platform?: string | null;
  platformSuppressed?: boolean;
  cancelled?: boolean;
}

export interface DarwinTripState {
  uid: string;
  serviceDate: string;
  rid: string | null;
  observedAt: string;
  locations: Map<string, DarwinLocationState>;
  alertIds: Set<string>;
}

export interface DarwinTripFeed {
  latestTrip(uid: string, serviceDate: string): Promise<DarwinTripState | null>;
}

function attributes(value: string): XMLAttributes {
  return Object.fromEntries([...value.matchAll(/([A-Za-z_][A-Za-z0-9_.:-]*)="([^"]*)"/gu)]
    .map((match) => [match[1] ?? "", match[2] ?? ""]));
}

function normalizedTimestamp(value: string): string {
  const trimmed = value.trim().replace(/(\.\d{3})\d+(?=[+-]\d{2}:\d{2}$|Z$)/u, "$1");
  const timestamp = Date.parse(trimmed);
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : new Date(0).toISOString();
}

function documentTimestamp(xml: string, fallback: string): string {
  const values = [...xml.matchAll(/<Pport\b([^>]*)>/gu)];
  const value = attributes(values.at(-1)?.[1] ?? "").ts;
  return value === undefined ? fallback : normalizedTimestamp(value);
}

function matchingAttributes(
  value: string,
  uid: string,
  serviceDate: string,
): XMLAttributes | null {
  const parsed = attributes(value);
  return parsed.uid === uid && parsed.ssd === serviceDate ? parsed : null;
}

function location(state: DarwinTripState, tpl: string): DarwinLocationState {
  const existing = state.locations.get(tpl);
  if (existing !== undefined) return existing;
  const created = { tpl };
  state.locations.set(tpl, created);
  return created;
}

function taggedValue(xml: string, tag: string): string | null {
  const match = xml.match(new RegExp(`<${tag}\\b[^>]*>([^<]*)<\\/${tag}>`, "u"));
  const value = match?.[1]?.trim();
  return value === undefined || value.length === 0 ? null : value;
}

function movementAttributes(xml: string, tag: "arr" | "dep" | "pass"): XMLAttributes | null {
  const match = xml.match(new RegExp(`<ns5:${tag}\\b([^>]*)\\/?>(?:<\\/ns5:${tag}>)?`, "u"));
  return match === null ? null : attributes(match[1] ?? "");
}

function updateMovement(value: DarwinLocationState, content: string, tag: "arr" | "dep" | "pass"): void {
  const movement = movementAttributes(content, tag);
  if (movement === null) return;
  const actualKey = tag === "arr" ? "actualArrival" : tag === "dep" ? "actualDeparture" : "actualPass";
  // Darwin explicitly retracts an actual event with atRemoved. A later estimate
  // or an unrelated patch alone does not retract an already reported movement.
  if (movement.atRemoved === "true") delete value[actualKey];
  else if (movement.at !== undefined) value[actualKey] = movement.at;
  if (tag === "pass") return;
  const expectedKey = tag === "arr" ? "expectedArrival" : "expectedDeparture";
  const expected = value[actualKey] ?? movement.et ?? movement.wet;
  if (expected !== undefined) value[expectedKey] = expected;
  else if (movement.atRemoved === "true") delete value[expectedKey];
}

function updateSchedule(
  state: DarwinTripState,
  body: string,
): void {
  const cancellationState = new Map<string, boolean>();
  for (const match of body.matchAll(/<ns2:(?:OR|OPOR|PP|IP|OPIP|DT|OPDT)\b([^>]*)\/?\s*>/gu)) {
    const parsed = attributes(match[1] ?? "");
    if (parsed.tpl !== undefined) cancellationState.set(parsed.tpl, parsed.can === "true");
  }

  for (const value of state.locations.values()) value.cancelled = cancellationState.get(value.tpl) ?? false;
  for (const [tpl, cancelled] of cancellationState) location(state, tpl).cancelled = cancelled;

  for (const id of [...state.alertIds]) {
    if (id.startsWith("darwin-cancellation-")) state.alertIds.delete(id);
  }
  const reason = taggedValue(body, "ns2:cancelReason");
  if (reason !== null && [...cancellationState.values()].some(Boolean)) {
    state.alertIds.add(`darwin-cancellation-${reason}`);
  }
}

function updateForecasts(state: DarwinTripState, body: string): void {
  // Each TS restates the service's late-running reason while one applies. A later TS
  // without it means the reason has lapsed, so the alert must not linger.
  for (const id of [...state.alertIds]) {
    if (id.startsWith("darwin-late-")) state.alertIds.delete(id);
  }
  for (const match of body.matchAll(/<ns5:LateReason\b[^>]*>([^<]*)<\/ns5:LateReason>/gu)) {
    const lateReason = match[1]?.trim();
    if (lateReason !== undefined && lateReason.length > 0) state.alertIds.add(`darwin-late-${lateReason}`);
  }

  for (const match of body.matchAll(/<ns5:Location\b([^>]*)>([\s\S]*?)<\/ns5:Location>/gu)) {
    const parsed = attributes(match[1] ?? "");
    if (parsed.tpl === undefined) continue;
    const content = match[2] ?? "";
    const value = location(state, parsed.tpl);
    updateMovement(value, content, "arr");
    updateMovement(value, content, "dep");
    updateMovement(value, content, "pass");

    const platform = content.match(/<ns5:plat\b([^>]*)>([^<]*)<\/ns5:plat>/u);
    const serviceSuppressed = /<ns5:suppr\b[^>]*>\s*true\s*<\/ns5:suppr>/u.test(content);
    if (platform !== null) {
      const platformAttributes = attributes(platform[1] ?? "");
      const suppressed = serviceSuppressed || platformAttributes.platsup === "true";
      value.platformSuppressed = suppressed;
      value.platform = suppressed ? null : (platform[2]?.trim() || null);
    } else if (serviceSuppressed) {
      value.platformSuppressed = true;
      value.platform = null;
    }
  }
}

function updateTrainAlerts(
  state: DarwinTripState,
  xml: string,
  uid: string,
  serviceDate: string,
): void {
  for (const match of xml.matchAll(/<trainAlert\b[^>]*>([\s\S]*?)<\/trainAlert>/gu)) {
    const body = match[1] ?? "";
    const services = [...body.matchAll(/<ns8:AlertService\b([^>]*)>/gu)]
      .map((service) => attributes(service[1] ?? ""));
    if (!services.some((service) => service.UID === uid && service.SSD === serviceDate)) continue;
    const alertId = taggedValue(body, "ns8:AlertID");
    if (alertId !== null) state.alertIds.add(`darwin-train-alert-${alertId}`);
  }
}

export function parseDarwinDocument(
  xml: string,
  uid: string,
  serviceDate: string,
  previous: DarwinTripState | null = null,
): DarwinTripState | null {
  let state = previous;
  const observedAt = documentTimestamp(xml, previous?.observedAt ?? new Date(0).toISOString());

  for (const match of xml.matchAll(/<schedule\b([^>]*)>([\s\S]*?)<\/schedule>/gu)) {
    const parsed = matchingAttributes(match[1] ?? "", uid, serviceDate);
    if (parsed === null) continue;
    state ??= {
      uid,
      serviceDate,
      rid: parsed.rid ?? null,
      observedAt,
      locations: new Map(),
      alertIds: new Set(),
    };
    state.rid = parsed.rid ?? state.rid;
    state.observedAt = observedAt;
    updateSchedule(state, match[2] ?? "");
  }

  for (const match of xml.matchAll(/<TS\b([^>]*)>([\s\S]*?)<\/TS>/gu)) {
    const parsed = matchingAttributes(match[1] ?? "", uid, serviceDate);
    if (parsed === null) continue;
    state ??= {
      uid,
      serviceDate,
      rid: parsed.rid ?? null,
      observedAt,
      locations: new Map(),
      alertIds: new Set(),
    };
    state.rid = parsed.rid ?? state.rid;
    state.observedAt = observedAt;
    updateForecasts(state, match[2] ?? "");
  }

  if (state !== null) updateTrainAlerts(state, xml, uid, serviceDate);
  return state;
}

function nativeStopCode(stationId: string): string {
  return stationId
    .replace(/^.*gb-great-britain_9100/iu, "")
    .replace(/:sup$/iu, "")
    .toUpperCase();
}

function matchingLocation(stop: StopSnapshot, state: DarwinTripState): DarwinLocationState | null {
  const native = nativeStopCode(stop.stationId);
  const candidates = [...state.locations.values()]
    .filter((value) => native.startsWith(value.tpl.toUpperCase()))
    .sort((left, right) => right.tpl.length - left.tpl.length);
  return candidates[0] ?? null;
}

function londonServiceDate(snapshot: TripSnapshot): string | null {
  const first = snapshot.stops.find((stop) => stop.countryCode.toUpperCase() === "GB");
  const timestamp = first?.scheduledDeparture ?? first?.scheduledArrival;
  if (timestamp === null || timestamp === undefined) return null;
  return serviceDateFormatter.format(new Date(timestamp));
}

function uid(snapshot: TripSnapshot): string | null {
  return snapshot.nativeId.match(/_([A-Z]\d{5})(?:_|$)/u)?.[1] ?? null;
}

// Darwin forecasts are UK wall-clock times. Resolve them with London's real offset
// on that day; guessing between UTC+0 and UTC+1 turned winter delays over 30 minutes
// into early running.
export function absoluteTime(localTime: string | undefined, anchor: string | null): string | undefined {
  if (localTime === undefined || anchor === null) return undefined;
  const resolved = nearestZonedClockTime("Europe/London", localTime, Date.parse(anchor));
  return resolved === null ? undefined : new Date(resolved).toISOString();
}

export class DarwinRealtimeOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = sourceName;
  readonly supportedCountryCodes = new Set(["GB"]);

  constructor(private readonly feed: DarwinTripFeed) {}

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    const trainUID = uid(snapshot);
    const serviceDate = londonServiceDate(snapshot);
    if (trainUID === null || serviceDate === null) return [];
    const state = await this.feed.latestTrip(trainUID, serviceDate);
    if (state === null) return [];

    return snapshot.stops.flatMap((stop): PlatformObservation[] => {
      if (stop.countryCode.toUpperCase() !== "GB") return [];
      const value = matchingLocation(stop, state);
      if (value === null) return [];
      const expectedArrival = absoluteTime(
        value.expectedArrival,
        stop.scheduledArrival ?? stop.scheduledDeparture,
      );
      const expectedDeparture = absoluteTime(
        value.expectedDeparture,
        stop.scheduledDeparture ?? stop.scheduledArrival,
      );
      const actualTime = (clock: string | undefined, anchor: string | null) => {
        const time = absoluteTime(clock, anchor);
        const latest = Math.min(Date.parse(snapshot.fetchedAt), Date.parse(state.observedAt)) + 120_000;
        return time !== undefined && Number.isFinite(latest) && Date.parse(time) <= latest ? time : undefined;
      };
      // A TIPLOC alone cannot prove which visit an actual event belongs to on a
      // looping route. Keep that passage unconfirmed until a visit can be matched.
      const uniqueVisit = snapshot.stops.filter((candidate) =>
        nativeStopCode(candidate.stationId).startsWith(value.tpl.toUpperCase())).length === 1;
      const arrivalObservedAt = uniqueVisit
        ? actualTime(value.actualArrival, stop.scheduledArrival) : undefined;
      const passageObservedAt = uniqueVisit ? [
        actualTime(value.actualDeparture, stop.scheduledDeparture),
        actualTime(value.actualPass, stop.scheduledDeparture ?? stop.scheduledArrival),
      ].filter((time): time is string => time !== undefined).sort().at(-1) : undefined;
      const hasPlatform = value.platform !== undefined || value.platformSuppressed === true;
      if (
        !hasPlatform
        && expectedArrival === undefined
        && expectedDeparture === undefined
        && value.cancelled === undefined
        && arrivalObservedAt === undefined
        && passageObservedAt === undefined
      ) return [];
      return [{
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        ...(hasPlatform ? { expectedPlatform: value.platform ?? null } : {}),
        ...(value.platformSuppressed === true ? { platformSuppressed: true } : {}),
        ...(expectedArrival === undefined ? {} : { expectedArrival }),
        ...(expectedDeparture === undefined ? {} : { expectedDeparture }),
        ...(value.cancelled === undefined ? {} : { cancelled: value.cancelled }),
        ...(arrivalObservedAt === undefined ? {} : { arrivalObservedAt }),
        ...(passageObservedAt === undefined ? {} : { passed: true, passageObservedAt }),
        observedAt: state.observedAt,
        source: sourceName,
      }];
    });
  }

  async tripAlertIds(snapshot: TripSnapshot): Promise<string[]> {
    const trainUID = uid(snapshot);
    const serviceDate = londonServiceDate(snapshot);
    if (trainUID === null || serviceDate === null) return [];
    return [...(await this.feed.latestTrip(trainUID, serviceDate))?.alertIds ?? []];
  }
}

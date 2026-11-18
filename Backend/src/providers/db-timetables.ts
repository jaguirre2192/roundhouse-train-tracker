import { realtimeCandidateStops } from "./realtime-stop-candidates.js";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import { cachedLoad, ExpiringCache } from "./expiring-cache.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import { zonedParts, zonedWallClockToUTC } from "./zoned-time.js";

const defaultBaseURL = "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1";

interface XMLElement {
  attributes: Record<string, string>;
  body: string;
}

interface DBEvent {
  plannedTime: string | null;
  changedTime: string | null;
  plannedPlatform: string | null;
  changedPlatform: string | null;
  changedStatus: string | null;
  line: string | null;
  trainLabel: string | null;
}

interface DBStop {
  id: string;
  category: string | null;
  number: string | null;
  arrival: DBEvent | null;
  departure: DBEvent | null;
  alertIds: string[];
}

interface StationMatch {
  eva: string;
  name: string;
  meta?: string[];
}

interface EnrichmentResult {
  observations: PlatformObservation[];
  alertIds: string[];
}

interface PendingCall {
  result: { observation: PlatformObservation | null; alertIds: string[] } | null;
  completed: Promise<void>;
}

function embeddedEva(stop: StopSnapshot): string | null {
  // Only numeric IDs from known national GTFS namespaces encode an EVA. DHID
  // components and SNCF UUID digits must never be treated as station numbers.
  return stop.stationId.match(/(?:de-[^_]+_0*(80\d{5})|ch-[^_]+_Parent(80\d{5}))$/u)?.slice(1).find(Boolean) ?? null;
}

function decodeXML(value: string): string {
  return value
    .replaceAll("&quot;", "\"")
    .replaceAll("&apos;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&amp;", "&");
}

function parseAttributes(value: string): Record<string, string> {
  const attributes: Record<string, string> = {};
  const expression = /([\w:-]+)\s*=\s*(["'])(.*?)\2/gu;
  for (const match of value.matchAll(expression)) {
    if (match[1] !== undefined && match[3] !== undefined) attributes[match[1]] = decodeXML(match[3]);
  }
  return attributes;
}

function elements(xml: string, tag: string): XMLElement[] {
  const expression = new RegExp(`<${tag}\\b([^>]*)>([\\s\\S]*?)<\\/${tag}>|<${tag}\\b([^>]*)\\/>`, "gu");
  return [...xml.matchAll(expression)].map((match) => ({
    attributes: parseAttributes(match[1] ?? match[3] ?? ""),
    body: match[2] ?? "",
  }));
}

function value(attributes: Record<string, string>, key: string): string | null {
  const result = attributes[key]?.trim();
  return result === undefined || result.length === 0 ? null : result;
}

function parseEvent(body: string, tag: "ar" | "dp"): DBEvent | null {
  const element = elements(body, tag)[0];
  if (element === undefined) return null;
  return {
    plannedTime: value(element.attributes, "pt"),
    changedTime: value(element.attributes, "ct"),
    plannedPlatform: value(element.attributes, "pp"),
    changedPlatform: value(element.attributes, "cp"),
    changedStatus: value(element.attributes, "cs"),
    line: value(element.attributes, "l"),
    trainLabel: value(element.attributes, "fb"),
  };
}

function parseStops(xml: string): DBStop[] {
  return elements(xml, "s").flatMap((element): DBStop[] => {
    const id = value(element.attributes, "id");
    if (id === null) return [];
    const label = elements(element.body, "tl")[0]?.attributes;
    const messageIds = elements(element.body, "m").flatMap((message) => {
      const id = value(message.attributes, "id");
      const type = value(message.attributes, "t");
      return id !== null && (type === "h" || type === "r" || type === "d") ? [`db:${id}`] : [];
    });
    return [{
      id,
      category: label === undefined ? null : value(label, "c"),
      number: label === undefined ? null : value(label, "n"),
      arrival: parseEvent(element.body, "ar"),
      departure: parseEvent(element.body, "dp"),
      alertIds: messageIds,
    }];
  });
}

function normalizeName(value: string): string {
  return value
    .normalize("NFKD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/\b(?:hauptbahnhof|hbf|bahnhof|bhf|zob)\b/giu, " ")
    .replace(/^[su](?:\+[su])?\s+/iu, "")
    .replace(/[^\p{Letter}\p{Number}]+/gu, " ")
    .trim()
    .toLowerCase();
}

function stationQueries(name: string): string[] {
  const stripped = name.replace(/^[SU](?:\+[SU])?\s+/u, "").trim();
  const berlinSuburb = stripped.match(/^(.+?)\s+Bhf\s+\(Berlin\)$/iu)?.[1];
  const values = [
    ...(berlinSuburb === undefined ? [] : [`Berlin ${berlinSuburb}`, `Berlin-${berlinSuburb}`]),
    stripped,
    stripped.replace(/\bHauptbahnhof\b/giu, "Hbf"),
    stripped.replace(/,?\s*(?:Bahnhof\/ZOB|Hauptbahnhof|Bahnhof|Bhf)\b.*$/iu, "").trim(),
  ];
  return [...new Set(values.filter((candidate) => candidate.length > 0))];
}

function stationScore(candidate: StationMatch, requestedName: string): number {
  const requested = normalizeName(requestedName);
  const actual = normalizeName(candidate.name);
  if (actual === requested) return 100;
  const requestedTokens = new Set(requested.split(" ").filter(Boolean));
  const actualTokens = new Set(actual.split(" ").filter(Boolean));
  if (requestedTokens.size === actualTokens.size && [...requestedTokens].every((token) => actualTokens.has(token))) return 100;
  return [...requestedTokens].filter((token) => actualTokens.has(token)).length;
}

function twoDigits(value: number): string {
  return String(value % 100).padStart(2, "0");
}

function dbPlanSlice(iso: string): { date: string; hour: string } | null {
  const parsed = Date.parse(iso);
  if (!Number.isFinite(parsed)) return null;
  const parts = zonedParts(parsed, "Europe/Berlin");
  return {
    date: `${twoDigits(parts.year)}${twoDigits(parts.month)}${twoDigits(parts.day)}`,
    hour: twoDigits(parts.hour),
  };
}

function dbTime(value: string | null): string | null {
  if (value === null || !/^\d{10}$/u.test(value)) return null;
  return new Date(zonedWallClockToUTC(
    "Europe/Berlin",
    2000 + Number(value.slice(0, 2)),
    Number(value.slice(2, 4)),
    Number(value.slice(4, 6)),
    Number(value.slice(6, 8)),
    Number(value.slice(8, 10)),
  )).toISOString();
}

function identityValues(stop: DBStop): string[] {
  const eventValues = [stop.arrival?.line, stop.arrival?.trainLabel, stop.departure?.line, stop.departure?.trainLabel];
  return [
    stop.category !== null && stop.number !== null ? `${stop.category}${stop.number}` : null,
    ...eventValues,
  ].flatMap((candidate) => candidate === null || candidate === undefined
    ? []
    : [candidate.replace(/[^\p{Letter}\p{Number}]+/gu, "").toUpperCase()]);
}

function productMatches(snapshot: TripSnapshot, stop: DBStop): boolean {
  const product = snapshot.product.replace(/[^\p{Letter}\p{Number}]+/gu, "").toUpperCase();
  if (product.length > 0 && identityValues(stop).some((candidate) => candidate === product)) return true;
  // DELFI publishes regional services as "RE4 (3180)": the number in
  // parentheses is the operating train number; RE4 is its passenger line.
  const numberedLine = snapshot.product.match(/^([\p{Letter}]+)\s*\d*\s*\((\d+)\)$/u);
  if (numberedLine === null || stop.number !== numberedLine[2]) return false;
  const line = snapshot.product.slice(0, snapshot.product.indexOf("(")).replace(/\s+/gu, "").toUpperCase();
  return stop.category?.toUpperCase() === numberedLine[1]?.toUpperCase()
    || [stop.arrival?.line, stop.arrival?.trainLabel, stop.departure?.line, stop.departure?.trainLabel]
      .some((value) => value?.replace(/\s+/gu, "").toUpperCase() === line);
}

function scheduled(stop: StopSnapshot): string | null {
  return stop.scheduledDeparture ?? stop.scheduledArrival;
}

function matchingPlanStop(snapshot: TripSnapshot, stop: StopSnapshot, plannedStops: DBStop[]): DBStop | null {
  const scheduledValue = scheduled(stop);
  if (scheduledValue === null) return null;
  const scheduledMilliseconds = Date.parse(scheduledValue);
  const candidates = plannedStops.filter((candidate) => productMatches(snapshot, candidate)).map((candidate) => {
    const event = stop.scheduledDeparture !== null ? candidate.departure : candidate.arrival;
    const planned = dbTime(event?.plannedTime ?? null);
    return { candidate, difference: planned === null ? Number.POSITIVE_INFINITY : Math.abs(Date.parse(planned) - scheduledMilliseconds) };
  }).filter((candidate) => candidate.difference <= 60_000)
    .sort((left, right) => left.difference - right.difference);
  if (candidates.length > 1 && candidates[0]!.difference === candidates[1]!.difference) return null;
  return candidates[0]?.candidate ?? null;
}

function observation(
  stop: StopSnapshot,
  planned: DBStop,
  changed: DBStop | null,
  observedAt: string,
  changesLoaded = true,
): PlatformObservation | null {
  const plannedEvent = stop.scheduledDeparture !== null ? planned.departure : planned.arrival;
  const changedEvent = stop.scheduledDeparture !== null ? changed?.departure : changed?.arrival;
  if (plannedEvent === null) return null;
  const plannedPlatform = changedEvent?.plannedPlatform ?? plannedEvent.plannedPlatform;
  const expectedPlatform = changesLoaded ? changedEvent?.changedPlatform ?? plannedPlatform : undefined;
  // fchg is the full current change set. A removed ct/cs restores the plan; an
  // unavailable change feed is unknown and must not erase existing realtime.
  const expectedArrival = !changesLoaded || stop.scheduledArrival === null ? undefined
    : dbTime(changed?.arrival?.changedTime ?? planned.arrival?.plannedTime ?? null) ?? undefined;
  const expectedDeparture = !changesLoaded || stop.scheduledDeparture === null ? undefined
    : dbTime(changed?.departure?.changedTime ?? planned.departure?.plannedTime ?? null) ?? undefined;
  const statuses = [
    ...(stop.scheduledArrival === null ? [] : [changed?.arrival?.changedStatus]),
    ...(stop.scheduledDeparture === null ? [] : [changed?.departure?.changedStatus]),
  ].filter((status): status is string => status !== null && status !== undefined);
  const cancelled = changesLoaded ? statuses.includes("c") : undefined;
  if (plannedPlatform === null && expectedPlatform == null && expectedArrival === undefined
    && expectedDeparture === undefined && cancelled === undefined) return null;
  return {
    stopSequence: stop.sequence,
    stationId: stop.stationId,
    plannedPlatform,
    expectedPlatform,
    ...(expectedArrival === undefined ? {} : { expectedArrival }),
    ...(expectedDeparture === undefined ? {} : { expectedDeparture }),
    ...(cancelled === undefined ? {} : { cancelled }),
    observedAt,
    source: "DB Timetables",
  };
}

export class DBTimetablesOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = "DB Timetables";
  readonly supportedCountryCodes = new Set(["DE"]);
  private readonly stationCache = new ExpiringCache<Promise<StationMatch | null>>(500);
  // Planned hourly slices barely change, but a long-running process sees every station
  // and hour of the day; expire them and evict failures so one bad fetch is retried.
  private readonly planCache = new ExpiringCache<Promise<DBStop[]>>(300);
  private readonly changesCache = new ExpiringCache<Promise<DBStop[]>>(200);
  private readonly callCache = new ExpiringCache<PendingCall>(500);
  private readonly relatedStationCache = new ExpiringCache<Promise<string[]>>(200);

  constructor(
    private readonly clientId: string,
    private readonly apiKey: string,
    private readonly baseURL = defaultBaseURL,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
    private readonly collectionMilliseconds = 2_500,
  ) {}

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    return (await this.enrich(snapshot)).observations;
  }

  async tripAlertIds(snapshot: TripSnapshot): Promise<string[]> {
    return (await this.enrich(snapshot)).alertIds;
  }

  private async enrich(snapshot: TripSnapshot): Promise<EnrichmentResult> {
    const calls = realtimeCandidateStops(snapshot, (stop) => stop.countryCode === "DE", 2)
      .map((stop) => this.call(snapshot, stop));
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      // A slow or failed station must not discard a completed station's update.
      // The unfinished work retains its state and warms the next watcher cycle.
      await Promise.race([
        Promise.all(calls.map((call) => call.completed)),
        new Promise<void>((resolve) => { timer = setTimeout(resolve, this.collectionMilliseconds); }),
      ]);
    } finally {
      clearTimeout(timer);
    }
    return {
      observations: calls.flatMap((call) => call.result?.observation == null ? [] : [call.result.observation]),
      alertIds: [...new Set(calls.flatMap((call) => call.result?.alertIds ?? []))],
    };
  }

  private call(snapshot: TripSnapshot, stop: StopSnapshot): PendingCall {
    const key = JSON.stringify([snapshot.id, snapshot.product, stop.stationId, stop.sequence,
      stop.scheduledArrival, stop.scheduledDeparture]);
    const cached = this.callCache.get(key, this.now().getTime());
    if (cached !== undefined) return cached;
    const call: PendingCall = { result: null, completed: Promise.resolve() };
    this.callCache.set(key, call, this.now().getTime(), 30_000);
    call.completed = this.loadCall(snapshot, stop, call).catch((error: unknown) => {
      console.error("DB Timetables station enrichment failed", { station: stop.stationName, error });
    }).finally(() => { this.callCache.set(key, call, this.now().getTime(), 15_000); });
    return call;
  }

  private async loadCall(snapshot: TripSnapshot, stop: StopSnapshot, call: PendingCall): Promise<void> {
    const eva = embeddedEva(stop);
    const station = eva === null ? await this.station(stop.stationName) : { eva, name: stop.stationName };
    const scheduledValue = scheduled(stop);
    const slice = scheduledValue === null ? null : dbPlanSlice(scheduledValue);
    if (station === null || slice === null) return;
    let planned: DBStop | null = null;
    let changes: DBStop[] | null = null;
    let selectedEva = station.eva;
    const update = () => {
      if (planned === null) return;
      const changed = changes?.find((candidate) => candidate.id === planned!.id) ?? null;
      call.result = {
        observation: observation(stop, planned, changed, this.now().toISOString(), changes !== null),
        alertIds: changed?.alertIds ?? [],
      };
    };
    const results = await Promise.allSettled([
      this.plan(station.eva, slice.date, slice.hour).then(async (plan) => {
        planned = matchingPlanStop(snapshot, stop, plan);
        if (planned === null && station.meta !== undefined) {
          const related = await this.relatedStations(station);
          const matches = (await Promise.allSettled(related.map(async (relatedEva) => {
            const relatedPlan = await this.plan(relatedEva, slice.date, slice.hour);
            return { eva: relatedEva, planned: matchingPlanStop(snapshot, stop, relatedPlan) };
          }))).flatMap((result) => result.status === "fulfilled" && result.value.planned !== null
            ? [result.value] : []);
          if (matches.length === 1) {
            const match = matches[0]!;
            planned = match.planned;
            selectedEva = match.eva;
            changes = null;
            update();
            changes = await this.changes(match.eva);
          }
        }
        update();
      }),
      this.changes(station.eva).then((value) => {
        if (selectedEva === station.eva) { changes = value; update(); }
      }),
    ]);
    for (const result of results) if (result.status === "rejected") {
      console.error("DB Timetables station subfeed failed", { station: stop.stationName, error: result.reason });
    }
  }

  private station(name: string): Promise<StationMatch | null> {
    return cachedLoad(this.stationCache, normalizeName(name), this.now().getTime(), 24 * 60 * 60_000,
      () => this.loadStation(name));
  }

  private async loadStation(name: string): Promise<StationMatch | null> {
    const queries = stationQueries(name);
    // DB uses Hbf rather than Hauptbahnhof. Try the canonical spelling first,
    // avoiding a cold empty request before the useful plan/change requests.
    queries.sort((left, right) => Number(/Hauptbahnhof/iu.test(left)) - Number(/Hauptbahnhof/iu.test(right)));
    const query = async (nameQuery: string): Promise<StationMatch[]> => {
      const xml = await this.request(`station/${encodeURIComponent(nameQuery)}`);
      return elements(xml, "station").flatMap((element): StationMatch[] => {
        const eva = value(element.attributes, "eva");
        const stationName = value(element.attributes, "name");
        return eva === null || stationName === null || element.attributes.db !== "true"
          ? [] : [{ eva, name: stationName, meta: value(element.attributes, "meta")?.split("|") ?? [] }];
      });
    };
    let firstError: unknown;
    const first = await query(queries[0]!).catch((error: unknown) => { firstError = error; return []; });
    let matches = first.filter((candidate) => stationScore(candidate, name) >= 100);
    if (matches.length === 0) {
      const results = await Promise.allSettled(queries.slice(1).map(query));
      matches = results.flatMap((result) => result.status === "fulfilled" ? result.value : [])
        .filter((candidate) => stationScore(candidate, name) >= 100);
      if (matches.length === 0) {
        const failed = results.find((result) => result.status === "rejected");
        if (firstError !== undefined) throw firstError;
        if (failed?.status === "rejected") throw failed.reason;
      }
    }
    const unique = [...new Map(matches.map((candidate) => [candidate.eva, candidate])).values()];
    return unique.length === 1 ? unique[0]! : null;
  }

  private relatedStations(station: StationMatch): Promise<string[]> {
    return cachedLoad(this.relatedStationCache, station.eva, this.now().getTime(), 24 * 60 * 60_000, async () => {
      const direct = station.meta ?? [];
      const groups = await Promise.allSettled(direct.slice(0, 2).map(async (eva) => {
        const xml = await this.request(`station/${eva}`);
        return elements(xml, "station").flatMap((element) => {
          const members = value(element.attributes, "meta")?.split("|") ?? [];
          // Only follow the reverse link of the station we already identified.
          return members.includes(station.eva) ? members : [];
        });
      }));
      return [...new Set(groups.flatMap((result) => result.status === "fulfilled" ? result.value : []))]
        .filter((eva) => eva !== station.eva && /^80\d{5}$/u.test(eva)).slice(0, 6);
    });
  }

  private plan(eva: string, date: string, hour: string): Promise<DBStop[]> {
    return cachedLoad(this.planCache, `${eva}:${date}:${hour}`, this.now().getTime(), 60 * 60_000, () =>
      this.request(`plan/${eva}/${date}/${hour}`).then(parseStops));
  }

  private changes(eva: string): Promise<DBStop[]> {
    return cachedLoad(this.changesCache, eva, this.now().getTime(), 30_000, () =>
      this.request(`fchg/${eva}`).then(parseStops));
  }

  private async request(path: string): Promise<string> {
    const response = await this.fetcher(new URL(path, `${this.baseURL}/`), {
      headers: {
        accept: "application/xml",
        "DB-Client-Id": this.clientId,
        "DB-Api-Key": this.apiKey,
        "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`DB Timetables returned ${response.status}`);
    return response.text();
  }
}

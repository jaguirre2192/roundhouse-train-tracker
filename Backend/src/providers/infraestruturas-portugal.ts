import { realtimeCandidateStops } from "./realtime-stop-candidates.js";
import { createHash } from "node:crypto";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";

interface IpBoardObservation {
  stop: StopSnapshot;
  delayMinutes: number | null;
  cancelled: boolean;
  note: string;
}

interface SnapshotResult {
  observations: PlatformObservation[];
  alertIds: string[];
}

function trainNumber(snapshot: TripSnapshot): string | null {
  return snapshot.nativeId.match(/pt-Comboios-de-Portugal\(CP\)_([0-9]{1,6})_/iu)?.[1] ?? null;
}

function ipStationId(stationId: string): string | null {
  const code = stationId.match(/pt-Comboios-de-Portugal\(CP\)_94_([0-9]{1,5})$/iu)?.[1];
  return code === undefined ? null : `94${code.padStart(5, "0")}`;
}

function decodeHtml(value: string): string {
  const entities: Record<string, string> = {
    amp: "&",
    apos: "'",
    gt: ">",
    lt: "<",
    nbsp: " ",
    quot: '"',
  };
  return value.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/giu, (match, entity: string) => {
    if (entity.startsWith("#x")) return String.fromCodePoint(Number.parseInt(entity.slice(2), 16));
    if (entity.startsWith("#")) return String.fromCodePoint(Number.parseInt(entity.slice(1), 10));
    return entities[entity.toLowerCase()] ?? match;
  });
}

function text(value: string): string {
  return decodeHtml(value.replace(/<[^>]*>/gu, " ")).replace(/\s+/gu, " ").trim();
}

function boardNote(html: string, number: string, serviceDate: string): string | null {
  const rows = html.match(/<tr\b[^>]*>[\s\S]*?<\/tr>/giu) ?? [];
  const expectedHref = `nComboio=${number}&data=${serviceDate}`;
  const encodedHref = `nComboio=${number}&amp;data=${serviceDate}`;
  for (const row of rows) {
    if (!row.includes(expectedHref) && !row.includes(encodedHref)) continue;
    const cells = [...row.matchAll(/<td\b[^>]*>([\s\S]*?)<\/td>/giu)].map((match) => text(match[1] ?? ""));
    return cells[6] ?? "";
  }
  return null;
}

function delayMinutes(note: string): number | null {
  const match = note.match(/atraso\s+de\s+(\d{1,4})\s*min/iu);
  return match === null ? null : Number(match[1]);
}

function isCancelled(note: string): boolean {
  return /\b(suprimid[oa]|supress[aã]o|cancelad[oa])\b/iu.test(note);
}

function shifted(value: string | null, minutes: number | null): string | null | undefined {
  if (value === null || minutes === null) return undefined;
  const epoch = Date.parse(value);
  return Number.isFinite(epoch) ? new Date(epoch + minutes * 60_000).toISOString() : undefined;
}

export class InfraestruturasPortugalOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = "Infraestruturas de Portugal public station board";
  readonly supportedCountryCodes = new Set(["PT"]);
  private readonly stationCache = new Map<string, { loadedAt: number; html: string }>();
  private readonly requests = new Map<string, Promise<string>>();
  private readonly snapshotCache = new Map<string, { loadedAt: number; value: SnapshotResult }>();

  constructor(
    private readonly baseUrl = "https://servicos.infraestruturasdeportugal.pt",
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    return (await this.snapshotResult(snapshot, true)).observations;
  }

  async tripAlertIds(snapshot: TripSnapshot): Promise<string[]> {
    return (await this.snapshotResult(snapshot, true)).alertIds;
  }

  cachedOverlay(): PlatformRealtimeOverlay {
    return {
      sourceName: this.sourceName,
      supportedCountryCodes: this.supportedCountryCodes,
      platformUpdates: async (snapshot) => (await this.snapshotResult(snapshot, false)).observations,
      tripAlertIds: async (snapshot) => (await this.snapshotResult(snapshot, false)).alertIds,
    };
  }

  private async snapshotResult(snapshot: TripSnapshot, loadIfMissing: boolean): Promise<SnapshotResult> {
    const number = trainNumber(snapshot);
    if (number === null) return { observations: [], alertIds: [] };
    const key = `${snapshot.nativeId}:${snapshot.serviceDate}`;
    const now = this.now().getTime();
    const cached = this.snapshotCache.get(key);
    if (cached !== undefined && now - cached.loadedAt < 25_000) return cached.value;

    const candidates = realtimeCandidateStops(snapshot, (stop) => {
      if (stop.countryCode.toUpperCase() !== "PT" || ipStationId(stop.stationId) === null) return false;
      const event = Date.parse(stop.scheduledDeparture ?? stop.scheduledArrival ?? "");
      return Number.isFinite(event) && event >= now - 2 * 60 * 60_000 && event <= now + 6 * 60 * 60_000;
    }, 1);
    let pageUnavailable = false;
    const values = (await Promise.all(candidates.map(async (stop): Promise<IpBoardObservation | null> => {
      const station = ipStationId(stop.stationId);
      if (station === null) return null;
      try {
        const page = await this.stationPage(station, loadIfMissing);
        if (page === null) {
          pageUnavailable = true;
          return null;
        }
        const note = boardNote(page, number, snapshot.serviceDate);
        if (note === null) return null;
        return { stop, note, delayMinutes: delayMinutes(note), cancelled: isCancelled(note) };
      } catch (error) {
        console.warn("IP station board fetch failed", { stationId: station, error });
        return null;
      }
    }))).filter((value): value is IpBoardObservation => value !== null);
    const observedAt = this.now().toISOString();
    const observations = values.flatMap((value): PlatformObservation[] => {
      if (value.delayMinutes === null && !value.cancelled) return [];
      return [{
        stopSequence: value.stop.sequence,
        stationId: value.stop.stationId,
        expectedArrival: shifted(value.stop.scheduledArrival, value.delayMinutes),
        expectedDeparture: shifted(value.stop.scheduledDeparture, value.delayMinutes),
        cancelled: value.cancelled,
        observedAt,
        source: this.sourceName,
      }];
    });
    const alertIds = values.filter((value) => value.note.length > 0).map((value) => {
      const digest = createHash("sha256").update(value.note).digest("hex").slice(0, 16);
      return `ip-alert-${number}-${snapshot.serviceDate}-${value.stop.sequence}-${digest}`;
    });
    const value = { observations, alertIds };
    if (!pageUnavailable) {
      this.snapshotCache.set(key, { loadedAt: now, value });
      if (this.snapshotCache.size > 200) this.snapshotCache.clear();
    }
    return value;
  }

  private async stationPage(stationId: string, loadIfMissing: boolean): Promise<string | null> {
    const now = this.now().getTime();
    const cached = this.stationCache.get(stationId);
    if (cached !== undefined && now - cached.loadedAt < 60_000) return cached.html;
    if (!loadIfMissing) return null;
    const existing = this.requests.get(stationId);
    if (existing !== undefined) return existing;
    const request = this.fetcher(`${this.baseUrl}/estacoes?estacaoId=${encodeURIComponent(stationId)}`, {
      headers: {
        accept: "text/html,application/xhtml+xml",
        "user-agent": "TrainTracker/0.3 (free noncommercial passenger-information app)",
      },
      signal: AbortSignal.timeout(12_000),
    }).then(async (response) => {
      if (!response.ok) throw new Error(`IP station board returned ${response.status}`);
      const html = await response.text();
      this.stationCache.set(stationId, { loadedAt: this.now().getTime(), html });
      if (this.stationCache.size > 100) this.stationCache.clear();
      return html;
    }).finally(() => this.requests.delete(stationId));
    this.requests.set(stationId, request);
    return request;
  }
}

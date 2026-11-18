import { RailProviderUnavailableError } from "./rail-provider-error.js";
import { srbijaVozStation } from "./srbijavoz-stations.js";
import { validSrbijaVozDate } from "./srbijavoz-time.js";
import { srbijaVozConnections, type SrbijaVozConnection } from "./srbijavoz-types.js";

interface CacheEntry { expiresAt: number; connections: SrbijaVozConnection[]; fetchedAt: string }
export interface SrbijaVozTimetable { connections: SrbijaVozConnection[]; fetchedAt: string }

export class SrbijaVozAPI {
  private readonly cache = new Map<string, CacheEntry>();
  private readonly inFlight = new Map<string, Promise<SrbijaVozTimetable>>();
  private blockedUntil = 0;

  constructor(
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async connections(from: number, to: number, serviceDate: string): Promise<SrbijaVozTimetable> {
    if (from === to || srbijaVozStation(from) === undefined || srbijaVozStation(to) === undefined
      || !validSrbijaVozDate(serviceDate)) throw new RailProviderUnavailableError("Unsupported Srbijavoz route");
    const key = `${from}:${to}:${serviceDate}`;
    const cached = this.cache.get(key);
    if (cached !== undefined && cached.expiresAt > this.now().getTime()) return structuredClone(cached);
    const pending = this.inFlight.get(key);
    if (pending !== undefined) return structuredClone(await pending);
    if (this.blockedUntil > this.now().getTime()) {
      throw new RailProviderUnavailableError("Srbijavoz is temporarily limiting requests",
        Math.ceil((this.blockedUntil - this.now().getTime()) / 1000));
    }
    const request = this.load(from, to, serviceDate).finally(() => this.inFlight.delete(key));
    this.inFlight.set(key, request);
    const result = await request;
    if (this.cache.size >= 32) this.cache.delete(this.cache.keys().next().value!);
    this.cache.set(key, { ...structuredClone(result), expiresAt: this.now().getTime() + 30_000 });
    return structuredClone(result);
  }

  private async load(from: number, to: number, serviceDate: string): Promise<SrbijaVozTimetable> {
    const url = new URL("https://webapi1.srbvoz.rs/eKarta/api/listavozova/ListaVozova_Web");
    url.search = new URLSearchParams({
      stanicaod: String(from), stanicado: String(to), datum: serviceDate,
      brojputnika: "1", razred: "2",
    }).toString();
    let response: Response;
    try {
      response = await this.fetcher(url, {
        headers: { accept: "application/json", "user-agent": "TrainTrackerWatcher/0.2" },
        signal: AbortSignal.timeout(10_000),
      });
    } catch {
      throw new RailProviderUnavailableError("Srbijavoz timetable request failed");
    }
    if (response.status === 403 || response.status === 429) {
      const header = response.headers.get("retry-after");
      const seconds = header !== null && /^\d+$/u.test(header) ? Number(header) : NaN;
      const date = header === null ? NaN : Date.parse(header);
      const requested = Number.isFinite(seconds) ? this.now().getTime() + seconds * 1000 : date;
      this.blockedUntil = Number.isFinite(requested) && requested > this.now().getTime()
        ? requested : this.now().getTime() + 5 * 60_000;
    }
    if (!response.ok) throw new RailProviderUnavailableError(`Srbijavoz returned ${response.status}`);
    let data: unknown;
    try { data = await response.json(); } catch {
      throw new RailProviderUnavailableError("Srbijavoz returned invalid JSON");
    }
    const decoded = srbijaVozConnections.safeParse(data);
    if (!decoded.success || decoded.data.some((row) => row.odsifra !== from || row.dosifra !== to)) {
      throw new RailProviderUnavailableError("Srbijavoz returned an invalid timetable");
    }
    return { connections: decoded.data, fetchedAt: this.now().toISOString() };
  }
}

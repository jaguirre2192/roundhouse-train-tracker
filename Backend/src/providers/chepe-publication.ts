import { RailProviderUnavailableError } from "./rail-provider-error.js";

const scheduleURL = "https://chepe.mx/tren/horarios/";
const verifiedLifetime = 6 * 60 * 60_000;
const retryInterval = 60_000;

function normalizedPublication(html: string): string {
  return html
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/giu, " ")
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/giu, " ")
    .replace(/<[^>]+>/gu, " ")
    .replace(/&nbsp;|&#160;/giu, " ")
    .replace(/&aacute;/giu, "á").replace(/&eacute;/giu, "é")
    .replace(/&iacute;/giu, "í").replace(/&oacute;/giu, "ó").replace(/&uacute;/giu, "ú")
    .normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase()
    .replace(/\s+/gu, " ").trim();
}

/** Never substitutes the timetable for an unavailable or changed publication. */
export class ChepePublicationVerifier {
  private verifiedAt: number | null = null;
  private retryAt = 0;
  private failure: RailProviderUnavailableError | null = null;
  private pending: Promise<void> | null = null;

  constructor(
    private readonly fetcher: typeof fetch,
    private readonly now: () => Date,
    private readonly signatures: readonly string[],
  ) {}

  ensureCurrent(): Promise<void> {
    const now = this.now().getTime();
    if (this.verifiedAt !== null && now >= this.verifiedAt && now - this.verifiedAt < verifiedLifetime) {
      return Promise.resolve();
    }
    if (this.pending !== null) return this.pending;
    if (this.failure !== null && now < this.retryAt) {
      return Promise.reject(new RailProviderUnavailableError(this.failure.message, Math.ceil((this.retryAt - now) / 1_000)));
    }
    this.pending = this.verify().finally(() => { this.pending = null; });
    return this.pending;
  }

  private async verify(): Promise<void> {
    try {
      const response = await this.fetcher(scheduleURL, {
        headers: {
          accept: "text/html",
          "user-agent": "Roundhouse/0.1.0 (+https://gettraintracker.com/support)",
        },
        signal: AbortSignal.timeout(10_000),
      });
      if (!response.ok) throw new RailProviderUnavailableError("Chepe timetable publication is temporarily unavailable");
      const publication = normalizedPublication(await response.text());
      const matches = this.signatures.length > 0 && this.signatures.every(value => {
        const signature = normalizedPublication(value);
        return signature.length > 0 && publication.includes(signature);
      });
      if (!matches) {
        throw new RailProviderUnavailableError("Chepe timetable publication could not be verified; refusing to serve an unverified schedule");
      }
      this.verifiedAt = this.now().getTime();
      this.failure = null;
      this.retryAt = 0;
    } catch (error) {
      this.failure = error instanceof RailProviderUnavailableError ? error
        : new RailProviderUnavailableError("Chepe timetable publication is temporarily unavailable");
      this.retryAt = this.now().getTime() + retryInterval;
      throw this.failure;
    }
  }
}

/** Small local queue; an optional persistent reservation coordinates service
 * recreation as well. Reservations happen immediately before sending, so a
 * suspended timer cannot wake a batch of pre-reserved requests into a burst. */
export class ProviderRequestPacer {
  private tail: Promise<void> = Promise.resolve();
  private queued = 0;
  private lastSentAt: number | null = null;

  constructor(
    private readonly reserve: () => Promise<boolean> = async () => true,
    private readonly spacingMs = 500,
    private readonly maximumQueued = 32,
  ) {}

  wait(): Promise<void> {
    if (this.queued >= this.maximumQueued) return Promise.reject(new Error("Provider request queue is full"));
    this.queued++;
    const queuedAt = Date.now();
    const work = this.tail.then(() => this.acquire(queuedAt));
    this.tail = work.catch(() => undefined);
    return work.finally(() => { this.queued--; });
  }

  private async acquire(started: number): Promise<void> {
    for (;;) {
      const now = Date.now();
      if (!Number.isFinite(now) || now < started || now - started > 15_000
        || (this.lastSentAt !== null && now < this.lastSentAt)) {
        throw new Error("Provider request reservation unavailable");
      }
      const remaining = this.lastSentAt === null ? 0 : this.spacingMs - (now - this.lastSentAt);
      if (remaining > 0) {
        await new Promise<void>((resolve) => setTimeout(resolve, remaining));
        continue;
      }
      if (await this.reserve()) { this.lastSentAt = Date.now(); return; }
      await new Promise<void>((resolve) => setTimeout(resolve, this.spacingMs));
    }
  }
}

import type { PushSender } from "../apns/transport.js";
import { ProviderRegistry } from "../providers/provider.js";
import { WatcherCycle, type WatcherLogger } from "./watcher-cycle.js";
import type { WatcherPersistence } from "./watcher-persistence.js";

export class Watcher {
  private timer: NodeJS.Timeout | null = null;
  private running = false;
  private readonly cycle: WatcherCycle;

  constructor(
    private readonly repository: WatcherPersistence,
    private readonly providers: ProviderRegistry,
    private readonly pushSender: PushSender,
    private readonly logger: WatcherLogger,
  ) {
    this.cycle = new WatcherCycle(repository, providers, pushSender, logger);
  }

  start(intervalMilliseconds = 5_000): void {
    if (this.timer !== null) return;
    void this.tick();
    this.timer = setInterval(() => void this.tick(), intervalMilliseconds);
  }

  stop(): void {
    if (this.timer !== null) clearInterval(this.timer);
    this.timer = null;
  }

  async tick(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try {
      await this.cycle.tick();
    } catch (error) {
      this.logger.error({ error }, "watcher tick failed");
    } finally {
      this.running = false;
    }
  }
}

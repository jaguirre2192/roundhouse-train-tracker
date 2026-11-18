import type { DenmarkBusClient, DenmarkLockedMessage } from "./denmark-servicebus-http.js";
import { DenmarkBusError } from "./denmark-servicebus-request.js";

/** Only an explicit Azure large-message barrier selects AMQP. Every acquired
 * lock stays owned by its original transport until acknowledged or abandoned. */
export class DenmarkServiceBusFallback implements DenmarkBusClient {
  private readonly owners = new Map<string, DenmarkBusClient>();

  constructor(private readonly http: DenmarkBusClient, private readonly amqp: DenmarkBusClient) {}

  async receive(signal: AbortSignal): Promise<DenmarkLockedMessage | null> {
    let owner = this.http;
    let message: DenmarkLockedMessage | null;
    try { message = await owner.receive(signal); }
    catch (error) {
      if (!(error instanceof DenmarkBusError) || error.code !== "requires-amqp" || error.httpStatus !== 405) throw error;
      owner = this.amqp;
      message = await owner.receive(signal);
    }
    if (message !== null) this.owners.set(message.lock, owner);
    return message;
  }

  async settle(lock: string, action: "complete" | "abandon", signal?: AbortSignal): Promise<void> {
    const owner = this.owners.get(lock);
    if (owner === undefined) throw new DenmarkBusError(action, "invalid-lock");
    await owner.settle(lock, action, signal);
    this.owners.delete(lock);
  }

  async close(): Promise<void> {
    try { await this.amqp.close?.(); }
    finally { this.owners.clear(); }
  }
}

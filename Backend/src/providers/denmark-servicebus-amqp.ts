import { ServiceBusClient, type ServiceBusClientOptions, type ServiceBusReceivedMessage, type ServiceBusReceiver } from "@azure/service-bus";
import type { TokenCredential } from "@azure/core-auth";
import { DenmarkServiceBusAuth, denmarkServiceBusScope } from "./denmark-servicebus-auth.js";
import { denmarkSubscriptionEndpoint, type DenmarkBusClient, type DenmarkLockedMessage } from "./denmark-servicebus-http.js";
import { DenmarkBusError, denmarkOperation } from "./denmark-servicebus-request.js";

export const maximumDenmarkAmqpMessageBytes = 20 * 1_024 * 1_024;
export type DenmarkAmqpClientFactory = (host: string, credential: TokenCredential, options: ServiceBusClientOptions) => ServiceBusClient;
interface Held { message: ServiceBusReceivedMessage; receiver: ServiceBusReceiver }

/** One original broker delivery per receive. Fragmentation belongs to publication,
 * and no original delivery can complete until its caller acknowledges all parts. */
export class DenmarkServiceBusAmqp implements DenmarkBusClient {
  private readonly endpoint: URL;
  private readonly auth: DenmarkServiceBusAuth;
  private readonly held = new Map<string, Held>();
  private client: ServiceBusClient | null = null;
  private receiver: ServiceBusReceiver | null = null;

  constructor(subscription: string, clientID: string, clientSecret: string,
    fetcher: typeof fetch = (input, init) => fetch(input, init), private readonly now: () => number = () => Date.now(),
    private readonly factory: DenmarkAmqpClientFactory = (host, credential, options) => new ServiceBusClient(host, credential, options)) {
    this.endpoint = denmarkSubscriptionEndpoint(subscription);
    this.auth = new DenmarkServiceBusAuth(clientID, clientSecret, fetcher, now);
  }

  async receive(parent: AbortSignal): Promise<DenmarkLockedMessage | null> {
    return denmarkOperation("receive", parent, 15_000, async signal => {
        const receiver = this.connection();
        const messages = await receiver.receiveMessages(1, { maxWaitTimeInMs: 1_000, abortSignal: signal });
        if (messages.length === 0) return null;
        // The SDK's batching receiver issues exactly the requested link credit,
        // with credit_window=0 and autoaccept=false for peekLock.
        if (messages.length !== 1) {
          await Promise.allSettled(messages.map(message => receiver.abandonMessage(message)));
          throw new DenmarkBusError("receive", "invalid-response");
        }
        const message = messages[0]!;
        try {
        if (signal.aborted) throw new DenmarkBusError("receive", "deadline");
        const lock = message.lockToken;
        if (typeof lock !== "string" || !/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/iu.test(lock)
          || this.held.has(lock)) throw new DenmarkBusError("receive", "invalid-lock");
        const bytes = typeof message.body === "string" ? new TextEncoder().encode(message.body)
          : message.body instanceof Uint8Array ? message.body : null;
        if (bytes === null || bytes.byteLength === 0) throw new DenmarkBusError("receive", "invalid-response");
        if (bytes.byteLength > maximumDenmarkAmqpMessageBytes) throw new DenmarkBusError("receive", "body-limit");
        if (signal.aborted) throw new DenmarkBusError("receive", "deadline");
        const at = message.lockedUntilUtc?.getTime();
        this.held.set(lock, { message, receiver });
        return { bytes, lock, ...(at !== undefined && Number.isFinite(at) && at > this.now() ? { lockExpiresAt: at } : {}) };
        } catch (error) {
          await denmarkOperation("abandon", undefined, 3_000, () => receiver.abandonMessage(message)).catch(() => undefined);
          throw error;
        }
    });
  }

  async settle(lock: string, action: "complete" | "abandon", parent?: AbortSignal): Promise<void> {
    const owned = this.held.get(lock);
    if (owned === undefined) throw new DenmarkBusError(action, "invalid-lock");
    await denmarkOperation(action, parent, action === "abandon" ? 3_000 : 5_000, () =>
      action === "complete" ? owned.receiver.completeMessage(owned.message) : owned.receiver.abandonMessage(owned.message));
    this.held.delete(lock);
  }

  /** Must be awaited in the alarm's finally block. Connections never survive an alarm. */
  async close(): Promise<void> {
    const client = this.client, receiver = this.receiver;
    this.client = this.receiver = null;
    const outstanding = [...this.held.values()];
    this.held.clear();
    await Promise.allSettled(outstanding.map(owned => denmarkOperation("abandon", undefined, 1_000,
      () => owned.receiver.abandonMessage(owned.message))));
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      // Start both closes, even if receiver.close never settles. The total close
      // budget remains below the alarm caller's independent three-second guard.
      await Promise.race([Promise.allSettled([receiver?.close(), client?.close()]),
        new Promise<void>(resolve => { timer = setTimeout(resolve, 1_800); })]);
    } finally { if (timer !== undefined) clearTimeout(timer); }
  }

  private connection(): ServiceBusReceiver {
    if (this.receiver !== null) return this.receiver;
    const credential: TokenCredential = { getToken: async (scopes, options) => {
      const requested = typeof scopes === "string" ? [scopes] : scopes;
      // Azure core-amqp7.10.0's audience has a trailing slash. Accept only its
      // exact default scope and our existing equivalent Service Bus scope.
      if (requested.length !== 1 || ![denmarkServiceBusScope, "https://servicebus.azure.net//.default"].includes(requested[0]!)) {
        throw new DenmarkBusError("oauth", "invalid-response");
      }
      return this.auth.accessToken(options?.abortSignal as AbortSignal | undefined);
    } };
    this.client = this.factory(this.endpoint.hostname, credential, { retryOptions: { maxRetries: 0, timeoutInMs: 5_000 } });
    const parts = this.endpoint.pathname.split("/");
    this.receiver = this.client.createReceiver(parts[1]!, parts[3]!, {
      receiveMode: "peekLock", maxAutoLockRenewalDurationInMs: 0, skipParsingBodyAsJson: true,
    });
    return this.receiver;
  }
}

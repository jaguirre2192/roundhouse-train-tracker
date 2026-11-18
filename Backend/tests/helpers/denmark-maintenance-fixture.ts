import { vi } from "vitest";
import { DenmarkRealtimeMaintenance, type DenmarkPollStorage } from "../../src/cloudflare/denmark-realtime-maintenance.js";
import type { DenmarkLockedMessage } from "../../src/providers/denmark-servicebus-http.js";

export function maintenanceFixture(maximumMessages = 14) {
  let values = new Map<string, unknown>(), queue = Promise.resolve();
  const start = Date.parse("2026-11-17T20:00:00Z"); let now = start, alarm: number | null = null, serial = 0;
  const writes = { state: 0, alarm: 0 }, faults = { put: false, alarm: false };
  const storage: DenmarkPollStorage = {
    get: async <T>(key: string) => structuredClone(values.get(key)) as T | undefined,
    transaction: work => {
      const result = queue.then(async () => {
        const next = structuredClone(values); let nextAlarm = alarm, puts = 0, alarms = 0;
        const result = await work({
          getAlarm: async () => nextAlarm,
          put: async (key, value) => { if (faults.put) throw new Error("fixture write failure"); puts++; next.set(key, structuredClone(value)); },
          setAlarm: async at => { if (faults.alarm) throw new Error("fixture alarm failure"); alarms++; nextAlarm = at; },
        });
        values = next; alarm = nextAlarm; writes.state += puts; writes.alarm += alarms; return result;
      });
      queue = result.then(() => undefined, () => undefined); return result;
    },
  };
  const events: string[] = [];
  const bus = {
    receive: vi.fn(async (): Promise<DenmarkLockedMessage | null> => {
      events.push("receive"); return { bytes: new Uint8Array([60]), lock: `private-lock-${++serial}`, lockExpiresAt: now + 60_000 };
    }),
    settle: vi.fn(async (_lock: string, action: "complete" | "abandon") => { events.push(action); }),
  };
  const publish = vi.fn(async (messages: readonly Uint8Array[], _signal: AbortSignal) => {
    events.push("publish"); return { deliveries: messages.length, ignoredStale: 0 };
  });
  const create = () => new DenmarkRealtimeMaintenance(storage, bus, publish, () => now, maximumMessages);
  const consumer = create();
  return { consumer, create, storage, events, bus, publish, writes, faults, start,
    setTime: (value: number) => { now = value; }, now: () => now, alarm: () => alarm,
    setValue: (key: string, value: unknown) => { values.set(key, structuredClone(value)); },
    fire: (instance = consumer) => { alarm = null; return instance.runAlarm(); },
  };
}

import {
  createExecutionContext,
  createScheduledController,
  env,
  runDurableObjectAlarm,
  runInDurableObject,
  SELF,
  waitOnExecutionContext,
} from "cloudflare:test";
import { describe, expect, it } from "vitest";
import worker from "../src/cloudflare/index.js";

const credential = "d".repeat(43);
const installationId = "aa141c63-e992-48ed-8c46-86cb6d42586a";

async function mutate(path: string, body: object): Promise<Response> {
  return SELF.fetch(`https://example.test${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Device ${credential}`,
      "CF-Connecting-IP": "198.51.100.40",
    },
    body: JSON.stringify(body),
  });
}

const today = new Date().toISOString().slice(0, 10);

describe("Cloudflare scheduled watcher recovery", () => {
  it("restarts the watcher alarm loop when active work exists", async () => {
    expect((await mutate("/v1/devices", {
      installationId,
      token: "a".repeat(64),
      environment: "sandbox",
      platform: "ios",
    })).status).toBe(204);
    expect((await mutate("/v1/subscriptions", {
      installationId,
      trip: {
        id: "us:amtraker:171-20",
        source: "amtraker",
        nativeId: "171-20",
        serviceDate: today,
      },
      boardingStationId: "us:amtraker:NYP",
      alightingStationId: "us:amtraker:PHL",
      watchFrom: new Date(Date.now() - 60_000).toISOString(),
      preferences: {
        delayThresholdMinutes: 5,
        platformChanges: true,
        cancellations: true,
        disruptions: true,
      },
    })).status).toBe(204);
    expect((await mutate("/v1/subscriptions", {
      installationId,
      trip: {
        id: "us:amtraker:172-20",
        source: "amtraker",
        nativeId: "172-20",
        serviceDate: today,
      },
      boardingStationId: "us:amtraker:PHL",
      alightingStationId: "us:amtraker:NYP",
      watchFrom: new Date(Date.now() - 60_000).toISOString(),
      preferences: {
        delayThresholdMinutes: 5,
        platformChanges: true,
        cancellations: true,
        disruptions: true,
      },
    })).status).toBe(204);

    const watcher = env.WATCHER.getByName("global");
    await runInDurableObject(watcher, async (_instance, state) => {
      state.storage.sql.exec("UPDATE tracked_trips SET source = 'unsupported'");
      await state.storage.deleteAlarm();
    });

    const ctx = createExecutionContext();
    await worker.scheduled(createScheduledController(), env, ctx);
    await waitOnExecutionContext(ctx);
    // The cron schedules the alarm; its execution context does not await the tick.
    expect(await runDurableObjectAlarm(watcher)).toBe(true);

    const health = await watcher.health();
    expect(health.lastTickAt).not.toBeNull();
    expect(health.alarmScheduledAt).not.toBeNull();
    expect(Date.now() - Date.parse(health.lastTickAt!)).toBeLessThanOrEqual(2_000);
    expect(health.lastTick?.tripsClaimed).toBe(2);
    const alarmDelay = Date.parse(health.alarmScheduledAt!) - Date.now();
    expect(alarmDelay).toBeGreaterThan(15_000);
    expect(alarmDelay).toBeLessThanOrEqual(21_000);
  });
});

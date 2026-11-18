import { env, SELF } from "cloudflare:test";
import { runInInitializedWatcher as runInDurableObject } from "./initialized-watcher.js";
import { describe, expect, it, vi } from "vitest";
import { createHash } from "node:crypto";
import { APNsError } from "../src/apns/transport.js";
import type { LiveActivityPush, LiveActivityRegistration } from "../src/domain/live-activity.js";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { LiveActivityStore } from "../src/cloudflare/live-activity-store.js";
import { LiveActivityOutbox } from "../src/cloudflare/live-activity-outbox.js";
import { LiveActivityService } from "../src/cloudflare/live-activity-service.js";
import { CloudflareLiveActivitySender } from "../src/cloudflare/live-activity-sender.js";

const credential = "l".repeat(43);
const context = { credentialHash: createHash("sha256").update(credential).digest("hex"), clientKey: "test-client" };

function registration(now = Date.now()): LiveActivityRegistration {
  return {
    schemaVersion: 1, installationId: crypto.randomUUID(), activityId: crypto.randomUUID(),
    token: crypto.randomUUID().replaceAll("-", "").repeat(2), tokenGeneration: 1, environment: "sandbox",
    trip: { id: "us:amtraker:171-20", source: "amtraker", nativeId: "171-20", serviceDate: "2026-09-07" },
    boardingStationId: "us:amtrak:NYP", alightingStationId: "us:amtrak:WAS", boardingStopSequence: 1,
    alightingStopSequence: 2, stationTimeZones: { "us:amtrak:NYP": "America/New_York", "us:amtrak:WAS": "America/New_York" },
    startedAt: new Date(now).toISOString(), initialContentState: {
      schemaVersion: 1, phase: "departureSoon", focusName: "New York Penn", eventTime: now / 1_000 + 60,
      timeZoneIdentifier: "America/New_York", timingBasis: "scheduled", platform: null, platformBasis: "unavailable",
      platformChanged: false, delayMinutes: null, checkedAt: now / 1_000, validUntil: now / 1_000 + 60, isStopCancelled: false,
    },
  };
}

function snapshot(input: LiveActivityRegistration, now: number, arrival = now + 3_600_000): TripSnapshot {
  const iso = (value: number) => new Date(value).toISOString();
  return { ...input.trip, operatorName: "Amtrak", product: "Northeast Regional", headsign: "Washington",
    fetchedAt: iso(now), alertIds: [], stops: [
      { stationId: input.boardingStationId, stationName: "New York Penn", sequence: 1, countryCode: "US",
        latitude: null, longitude: null, scheduledArrival: null, scheduledDeparture: iso(now + 60_000),
        expectedArrival: null, expectedDeparture: null, plannedPlatform: "4", expectedPlatform: null,
        platformSource: null, platformObservedAt: null, cancelled: false, passed: true },
      { stationId: input.alightingStationId, stationName: "Washington Union", sequence: 2, countryCode: "US",
        latitude: null, longitude: null, scheduledArrival: iso(arrival), scheduledDeparture: null,
        expectedArrival: null, expectedDeparture: null, plannedPlatform: null, expectedPlatform: null,
        platformSource: null, platformObservedAt: null, cancelled: false, passed: true },
    ] };
}

describe("Live Activity registration and delivery", () => {
  it("boots its own credential without alert enrollment, enforces ownership, and rejects resurrection after stop", async () => {
    const input = registration();
    const post = (body: unknown, auth = credential) => SELF.fetch("https://example.test/v1/live-activities", {
      method: "POST", headers: { authorization: `Device ${auth}`, "content-type": "application/json" }, body: JSON.stringify(body),
    });
    expect((await post(input)).status).toBe(204);
    expect((await post(input)).status).toBe(204);
    expect((await post(input, "x".repeat(43))).status).toBe(401);
    const rows = await runInDurableObject(env.WATCHER.getByName("global"), (_instance, state) => ({
      alerts: state.storage.sql.exec("SELECT * FROM devices WHERE installation_id = ?", input.installationId).toArray().length,
      activities: state.storage.sql.exec("SELECT * FROM live_activities WHERE installation_id = ?", input.installationId).toArray().length,
    }));
    expect(rows).toEqual({ alerts: 0, activities: 1 });
    expect(await runInDurableObject(env.WATCHER.getByName("global"), (_instance, state) => state.storage.getAlarm())).not.toBeNull();
    const conflictingDevice = await SELF.fetch("https://example.test/v1/devices", { method: "POST",
      headers: { authorization: `Device ${"x".repeat(43)}`, "content-type": "application/json" },
      body: JSON.stringify({ installationId: input.installationId, token: "c".repeat(64), environment: "sandbox", platform: "ios" }) });
    expect(conflictingDevice.status).toBe(401);
    expect((await SELF.fetch(`https://example.test/v1/live-activities/${input.activityId}?installationId=${input.installationId}`,
      { method: "DELETE", headers: { authorization: `Device ${credential}` } })).status).toBe(204);
    expect((await post(input)).status).toBe(409);
  });

  it("validates schema/body/auth and accepts Swift omitted optionals and its longest bounded name", async () => {
    const input = registration();
    const post = (body: unknown, authorization = `Device ${credential}`) => SELF.fetch("https://example.test/v1/live-activities", {
      method: "POST", headers: { authorization, "content-type": "application/json" }, body: JSON.stringify(body),
    });
    expect((await post(input, "")).status).toBe(401);
    expect((await post({ ...input, schemaVersion: 2 })).status).toBe(400);
    expect((await post({ ...input, token: "not-hex" })).status).toBe(400);
    expect((await post({ ...input, padding: "x".repeat(17_000) })).status).toBe(413);
    const { platform: _platform, delayMinutes: _delay, ...initialContentState } = input.initialContentState;
    expect((await post({ ...input, initialContentState: { ...initialContentState, focusName: "N".repeat(160) } })).status).toBe(204);
  });

  it("tombstones unknown stops, protects immutable selection, orders token rotation, and limits one active activity", async () => {
    const input = registration();
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), (_instance, state) => {
      const store = new LiveActivityStore(state.storage);
      const stopped = { ...input, activityId: crypto.randomUUID() };
      expect(store.stop(input.installationId, stopped.activityId, context)).toEqual({ allowed: true });
      expect(store.register(stopped, context).allowed).toBe(false);
      expect(store.register(input, context).allowed).toBe(true);
      expect(store.register({ ...input, activityId: crypto.randomUUID() }, context)).toEqual({ allowed: false, reason: "token_conflict" });
      expect(store.register({ ...input, activityId: crypto.randomUUID(), token: "e".repeat(64) }, context)).toEqual({ allowed: false, reason: "quota_exceeded" });
      expect(store.register({ ...input, token: "b".repeat(64), tokenGeneration: 2 }, context).allowed).toBe(true);
      expect(store.register(input, context).allowed).toBe(true);
      expect(store.get(input.activityId)?.tokenGeneration).toBe(2);
      expect(store.register({ ...input, token: "c".repeat(64), tokenGeneration: 2 }, context).allowed).toBe(false);
      expect(store.register({ ...input, tokenGeneration: 3, alightingStationId: "different" }, context).allowed).toBe(false);
    });
  });

  it("fetches once for a shared trip, ignores passed flags, retains freshness on failure and recovers", async () => {
    const now = Date.now();
    const input = registration(now);
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const sent: LiveActivityPush[] = [];
      const fetchTrip = vi.fn(async () => snapshot(input, now));
      const service = new LiveActivityService(state.storage, { fetchTrip }, { async send(push) { sent.push(push); } });
      expect(service.store.register(input, context, now).allowed).toBe(true);
      const second = { ...input, installationId: crypto.randomUUID(), activityId: crypto.randomUUID(), token: "b".repeat(64) };
      expect(service.store.register(second, context, now).allowed).toBe(true);
      await service.tick(now);
      expect(fetchTrip).toHaveBeenCalledTimes(1);
      expect(sent).toHaveLength(2);
      expect(service.store.get(input.activityId)?.status).toBe("active");
      const successfulContent = service.store.get(input.activityId)?.content;
      fetchTrip.mockRejectedValueOnce(new Error("offline"));
      await service.tick(now + 120_000);
      expect(service.store.get(input.activityId)?.content).toEqual(successfulContent);
      expect(sent).toHaveLength(2);
      fetchTrip.mockResolvedValue(snapshot(input, now + 180_000));
      await service.tick(now + 180_000);
      expect(service.store.get(input.activityId)?.content.checkedAt).toBe((now + 180_000) / 1_000);
      expect(sent).toHaveLength(4);
    });
  });

  it("keeps a delayed activity alive, marks unknown evidence honestly, and resumes updates", async () => {
    const now = Date.now();
    const input = registration(now);
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const sent: LiveActivityPush[] = [];
      const initial = snapshot(input, now, now + 120_000);
      initial.stops[0]!.scheduledDeparture = new Date(now - 60_000).toISOString();
      const fetchTrip = vi.fn(async () => initial);
      const service = new LiveActivityService(state.storage, { fetchTrip }, { async send(push) { sent.push(push); } });
      expect(service.store.register(input, context, now).allowed).toBe(true);
      await service.tick(now);
      expect(service.store.get(input.activityId)?.status).toBe("active");

      const delayedAt = now + 40 * 60_000;
      const position = { latitude: 39.5, longitude: -76.5, heading: null, source: "real" as const,
        confidence: 1, asOf: new Date(delayedAt).toISOString(), provider: "Amtraker" };
      fetchTrip.mockResolvedValue({ ...initial, fetchedAt: new Date(delayedAt).toISOString(), positions: [position] });
      await service.tick(delayedAt);
      expect(service.store.get(input.activityId)?.content.phase).toBe("underway");
      expect(service.store.get(input.activityId)?.status).toBe("active");
      expect(sent.at(-1)?.event).toBe("update");

      const missingAt = delayedAt + 6 * 60_000;
      fetchTrip.mockResolvedValue({ ...initial, fetchedAt: new Date(missingAt).toISOString() });
      await service.tick(missingAt);
      expect(service.store.get(input.activityId)?.content.phase).toBe("unavailable");
      expect(service.store.get(input.activityId)?.content.validUntil).toBeLessThanOrEqual(missingAt / 1_000);
      expect(service.store.get(input.activityId)?.status).toBe("active");
      expect(sent.at(-1)?.event).toBe("update");

      const recoveredAt = missingAt + 120_000;
      fetchTrip.mockResolvedValue({ ...initial, fetchedAt: new Date(recoveredAt).toISOString(),
        positions: [{ ...position, asOf: new Date(recoveredAt).toISOString() }] });
      await service.tick(recoveredAt);
      expect(service.store.get(input.activityId)?.content.phase).toBe("underway");
      expect(service.store.get(input.activityId)?.status).toBe("active");
      expect(sent.every((push) => push.event === "update")).toBe(true);
    });
  });

  it("rejects a start outside the selected travel window on its first successful provider check", async () => {
    const now = Date.now();
    const input = registration(now);
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const data = snapshot(input, now, now + 5 * 3_600_000);
      data.stops[0]!.scheduledDeparture = new Date(now + 2 * 3_600_000).toISOString();
      const sent: LiveActivityPush[] = [];
      const service = new LiveActivityService(state.storage, { async fetchTrip() { return data; } },
        { async send(message) { sent.push(message); } });
      service.store.register(input, context, now);
      await service.tick(now);
      expect(service.store.get(input.activityId)?.status).toBe("ended");
      expect(sent.at(-1)?.event).toBe("end");
    });
  });

  it("keeps a newer revision queued when an older send succeeds, and orders every update before end", async () => {
    const now = Date.now();
    const input = registration(now);
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const store = new LiveActivityStore(state.storage);
      store.register(input, context, now);
      store.successful(input.activityId, { ...input.initialContentState, platform: "3", platformBasis: "reported" }, false, now, now);
      const timestamps: number[] = [];
      const outbox = new LiveActivityOutbox(state.storage, store, { async send(message) {
        timestamps.push(message.timestamp);
        if (timestamps.length === 1) store.successful(input.activityId,
          { ...message.content, platform: "4" }, false, now, now);
      } });
      await outbox.deliver(now);
      expect(state.storage.sql.exec("SELECT 1 FROM live_activity_outbox").toArray()).toHaveLength(1);
      await outbox.deliver(now);
      store.stop(input.installationId, input.activityId, context, now);
      await outbox.deliver(now);
      expect(timestamps).toHaveLength(3);
      expect(timestamps[0]!).toBeLessThan(timestamps[1]!);
      expect(timestamps[1]!).toBeLessThan(timestamps[2]!);
      expect(store.get(input.activityId)?.status).toBe("ended");
    });
  });

  it("shares existing device ownership and rate limits live mutations", async () => {
    const now = Date.now();
    const input = registration(now);
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), (_instance, state) => {
      const store = new LiveActivityStore(state.storage);
      state.storage.sql.exec(`INSERT INTO devices
        (installation_id, apns_token, credential_hash, environment, platform, active, created_at, updated_at)
        VALUES (?, ?, ?, 'sandbox', 'ios', 1, ?, ?)`, input.installationId, "f".repeat(64), context.credentialHash, now, now);
      expect(store.register(input, { ...context, credentialHash: "mismatch" }, now)).toEqual({ allowed: false, reason: "unauthorized" });
      for (let index = 0; index < 29; index += 1) expect(store.register(input, context, now).allowed).toBe(true);
      expect(store.register(input, context, now)).toMatchObject({ allowed: false, reason: "rate_limited" });
      expect(store.register(input, context, now + 60_000).allowed).toBe(true);
    });
  });

  it("requires observed arrival for recovery closure and marks eight-hour technical expiry unavailable", async () => {
    const now = Date.now();
    const input = registration(now);
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      let data = snapshot(input, now, now + 120_000);
      const sent: LiveActivityPush[] = [];
      const fetchTrip = vi.fn(async () => data);
      const service = new LiveActivityService(state.storage, { fetchTrip }, { async send(push) { sent.push(push); } });
      service.store.register(input, context, now);
      await service.tick(now);
      data = { ...data, fetchedAt: new Date(now + 130_000).toISOString(),
        stops: data.stops.map((stop, index) => index === data.stops.length - 1
          ? { ...stop, arrivalObservedAt: new Date(now + 120_000).toISOString() } : stop) };
      await service.tick(now + 130_000);
      expect(service.store.get(input.activityId)?.content.phase).toBe("ended");
      expect(service.store.get(input.activityId)?.status).toBe("active");
      fetchTrip.mockRejectedValueOnce(new Error("provider unavailable"));
      await service.tick(now + 2_000_000);
      expect(service.store.get(input.activityId)?.status).toBe("active");
      data = { ...data, fetchedAt: new Date(now + 2_060_000).toISOString() };
      await service.tick(now + 2_060_000);
      expect(service.store.get(input.activityId)?.status).toBe("ended");
      expect(sent.at(-1)?.event).toBe("end");

      const hardExpiry = { ...input, activityId: crypto.randomUUID(), token: "b".repeat(64) };
      service.store.register(hardExpiry, context, now);
      fetchTrip.mockRejectedValue(new Error("offline"));
      await service.tick(now + 8 * 3_600_000);
      expect(service.store.get(hardExpiry.activityId)?.status).toBe("ended");
      expect(service.store.get(hardExpiry.activityId)?.content.phase).toBe("unavailable");
      expect(service.store.get(hardExpiry.activityId)?.token).toBe("");
    });
  });

  it("does not resurrect after stop during fetch or retire a rotated token on an old in-flight 410", async () => {
    const now = Date.now();
    const input = registration(now);
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const store = new LiveActivityStore(state.storage);
      store.register(input, context, now);
      store.successful(input.activityId, input.initialContentState, false, now, now);
      // Force a changed successful check to enqueue an update.
      store.successful(input.activityId, { ...input.initialContentState, checkedAt: now / 1_000 + 1 }, false, now, now);
      const outbox = new LiveActivityOutbox(state.storage, store, { async send() {
        store.register({ ...input, token: "b".repeat(64), tokenGeneration: 2 }, context, now);
        throw new APNsError(410, "Unregistered");
      } });
      await outbox.deliver(now);
      expect(store.get(input.activityId)?.status).toBe("active");
      expect(store.get(input.activityId)?.tokenGeneration).toBe(2);
      const service = new LiveActivityService(state.storage, { async fetchTrip() {
        store.stop(input.installationId, input.activityId, context, now);
        return snapshot(input, now);
      } }, { async send() {} });
      await service.tick(now);
      expect(store.get(input.activityId)?.status).toBe("ended");
      expect(store.register(input, context, now).allowed).toBe(false);
    });
  });

  it("bounds failed end delivery and rejects expired original starts without extending TTL on token rotation", async () => {
    const now = Date.now();
    const input = registration(now);
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const store = new LiveActivityStore(state.storage);
      store.register(input, context, now);
      const expiry = store.get(input.activityId)!.expiresAt;
      store.register({ ...input, token: "b".repeat(64), tokenGeneration: 2 }, context, now + 1_000);
      expect(store.get(input.activityId)?.expiresAt).toBe(expiry);
      store.stop(input.installationId, input.activityId, context, now);
      const outbox = new LiveActivityOutbox(state.storage, store, { async send() { throw new APNsError(503, "ServiceUnavailable"); } });
      await outbox.deliver(now);
      expect(store.hasWork()).toBe(true);
      store.expire(now + 15 * 60_000);
      expect(store.hasWork()).toBe(false);
      expect(store.get(input.activityId)?.token).toBe("");
      expect(store.register({ ...input, activityId: crypto.randomUUID() }, context, now + 8 * 3_600_000).allowed).toBe(false);
    });
  });
  it("queues an alert for a reported boarding track and keeps it through a quieter follow-up", async () => {
    const now = Date.now();
    const input = registration(now);
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const store = new LiveActivityStore(state.storage);
      store.register(input, context, now);
      const assigned = { ...input.initialContentState, platform: "7", platformBasis: "reported" as const, platformKind: "track" as const,
        boardingPlatformSequence: input.boardingStopSequence };
      store.successful(input.activityId, assigned, false, now, now);
      store.successful(input.activityId, { ...assigned, delayMinutes: 2 }, false, now, now + 1_000);
      const sent: LiveActivityPush[] = [];
      await new LiveActivityOutbox(state.storage, store, { async send(message) { sent.push(message); } }).deliver(now + 1_000);
      expect(sent).toHaveLength(1);
      expect(sent[0]?.alert).toEqual({ title: "Track 7", body: "Board at track 7 at New York Penn." });
      expect(sent[0]?.content.delayMinutes).toBe(2);

      store.successful(input.activityId, { ...assigned, delayMinutes: 3 }, false, now, now + 2_000);
      await new LiveActivityOutbox(state.storage, store, { async send(message) { sent.push(message); } }).deliver(now + 2_000);
      expect(sent[1]?.alert).toBeUndefined();
      // Preserve the ordinary update when a delivery retry wakes up after boarding.
      store.successful(input.activityId, { ...assigned, platform: "8" }, false, now, now + 3_000);
      await new LiveActivityOutbox(state.storage, store, { async send(message) { sent.push(message); } }).deliver(now + 60_000);
      expect(sent[2]?.alert).toBeUndefined();
    });
  });
});

describe("Live Activity APNs sender", () => {
  it("uses ActivityKit topic, silent priority five, expiry, and bounded requests", async () => {
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
    const bytes = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
    const privateKey = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...bytes))}\n-----END PRIVATE KEY-----`;
    const sender = new CloudflareLiveActivitySender({ mode: "live", teamId: "TEAM", keyId: "KEY", privateKey, bundleId: "com.example.train" });
    const input = registration();
    const message: LiveActivityPush = { activityId: input.activityId, token: input.token, tokenGeneration: 1,
      environment: "sandbox", revision: 1, timestamp: 1_800_000_000, event: "update", content: input.initialContentState, expiresAt: 1_800_000_300_000 };
    const fetch = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(null, { status: 200 }));
    try {
      await sender.send(message);
      expect(fetch.mock.calls[0]?.[0]).toBe(`https://api.sandbox.push.apple.com/3/device/${input.token}`);
      const request = fetch.mock.calls[0]?.[1];
      const headers = new Headers(request?.headers);
      expect(headers.get("apns-topic")).toBe("com.example.train.push-type.liveactivity");
      expect(headers.get("apns-push-type")).toBe("liveactivity");
      expect(headers.get("apns-priority")).toBe("5");
      expect(headers.get("apns-expiration")).toBe("1800000300");
      expect(JSON.parse(request?.body as string).aps).not.toHaveProperty("alert");

      await sender.send({ ...message, alert: { title: "Track 7", body: "Board at track 7 at New York Penn." } });
      expect(new Headers(fetch.mock.calls[1]?.[1]?.headers).get("apns-priority")).toBe("10");
      expect(new Headers(fetch.mock.calls[1]?.[1]?.headers).get("apns-expiration"))
        .toBe(String(Math.floor(Math.min(message.expiresAt / 1_000, message.content.validUntil, message.content.eventTime!))));
      expect(JSON.parse(fetch.mock.calls[1]?.[1]?.body as string).aps.alert.sound).toBe("default");
    } finally { fetch.mockRestore(); }
  });
});

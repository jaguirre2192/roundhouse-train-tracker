import { createHash } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import { makeApp } from "../src/http/app.js";
import type { DeviceMutationOutcome, WatcherRepository } from "../src/db/repository.js";
import { ProviderRegistry } from "../src/providers/provider.js";

const credential = "d".repeat(43);
const credentialHash = createHash("sha256").update(credential).digest("hex");
const installationId = "ba141c63-e992-48ed-8c46-86cb6d42586a";
const device = { installationId, token: "a".repeat(64), environment: "sandbox", platform: "ios" };
const subscription = {
  installationId,
  trip: { id: "us:amtraker:171-20", source: "amtraker", nativeId: "171-20", serviceDate: "2026-07-20" },
  boardingStationId: "us:amtraker:NYP",
  alightingStationId: "us:amtraker:PHL",
  watchFrom: "2026-07-20T18:00:00.000Z",
};

const apps: ReturnType<typeof makeApp>[] = [];

function appWith(outcome: DeviceMutationOutcome) {
  const calls: Array<{ method: string; credentialHash: unknown }> = [];
  const repository = {
    registerDevice: async (_input: unknown, hash: string) => { calls.push({ method: "register", credentialHash: hash }); return outcome; },
    subscribe: async (_input: unknown, hash: string) => { calls.push({ method: "subscribe", credentialHash: hash }); return outcome; },
    unsubscribe: async (_id: string, _trip: string, hash: string) => { calls.push({ method: "unsubscribe", credentialHash: hash }); return outcome; },
  } as unknown as WatcherRepository;
  const app = makeApp(repository, new ProviderRegistry([]), "silent");
  apps.push(app);
  return { app, calls };
}

afterEach(async () => {
  await Promise.all(apps.splice(0).map((app) => app.close()));
});

describe("self-hosted device mutations", () => {
  it("rejects every notification mutation without a device credential", async () => {
    const { app, calls } = appWith("allowed");
    const responses = await Promise.all([
      app.inject({ method: "POST", path: "/v1/devices", payload: device }),
      app.inject({ method: "POST", path: "/v1/subscriptions", payload: subscription }),
      app.inject({
        method: "DELETE",
        path: `/v1/subscriptions?installationId=${installationId}&tripId=${encodeURIComponent(subscription.trip.id)}`,
      }),
      app.inject({ method: "POST", path: "/v1/devices", payload: device, headers: { authorization: "Device short" } }),
    ]);
    expect(responses.map((response) => response.statusCode)).toEqual([401, 401, 401, 401]);
    expect(calls).toEqual([]);
  });

  it("passes only the credential hash to the repository", async () => {
    const { app, calls } = appWith("allowed");
    const headers = { authorization: `Device ${credential}` };
    expect((await app.inject({ method: "POST", path: "/v1/devices", payload: device, headers })).statusCode).toBe(204);
    expect((await app.inject({ method: "POST", path: "/v1/subscriptions", payload: subscription, headers })).statusCode).toBe(204);
    expect((await app.inject({
      method: "DELETE",
      path: `/v1/subscriptions?installationId=${installationId}&tripId=${encodeURIComponent(subscription.trip.id)}`,
      headers,
    })).statusCode).toBe(204);
    expect(calls).toEqual([
      { method: "register", credentialHash },
      { method: "subscribe", credentialHash },
      { method: "unsubscribe", credentialHash },
    ]);
  });

  it("maps repository refusals to the Worker's status codes", async () => {
    const headers = { authorization: `Device ${credential}` };
    for (const [outcome, status] of [
      ["unauthorized", 401],
      ["token_conflict", 409],
      ["trip_conflict", 409],
      ["quota_exceeded", 409],
    ] as const) {
      const { app } = appWith(outcome);
      const response = await app.inject({ method: "POST", path: "/v1/devices", payload: device, headers });
      expect(response.statusCode).toBe(status);
      expect(response.json()).toEqual({ error: outcome });
    }
  });

  it("rejects oversized JSON bodies with 413", async () => {
    const { app, calls } = appWith("allowed");
    const response = await app.inject({
      method: "POST",
      path: "/v1/shares",
      headers: { "content-type": "application/json" },
      payload: JSON.stringify({ padding: "x".repeat(70 * 1_024) }),
    });
    expect(response.statusCode).toBe(413);
    expect(calls).toEqual([]);
  });
});

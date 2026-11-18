import { createExecutionContext, env, runInDurableObject } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import worker from "../src/cloudflare/index.js";
import type { WorkerEnv } from "../src/cloudflare/env.js";
import { RailIndexStore } from "../src/cloudflare/rail-index-store.js";
import { maximumRegionalIndexBytes } from "../src/providers/trafiklab-regional-index-schema.js";
import { TrafiklabRegionalIndexSource } from "../src/providers/trafiklab-regional-index-source.js";
import type { RegionalRailIndex } from "../src/providers/trafiklab-regional-index.js";

const path = "/internal/rail-data/trafiklab-skane";
const secret = "rail-refresh-worker-test-secret-32-characters";
const prefix = "rail-index:skane:";
const dayMilliseconds = 86_400_000;
type IncomingRequest = Parameters<typeof worker.fetch>[0];

function index(dayOffset = 0, trips = 1): RegionalRailIndex {
  const generated = Math.floor(Date.now() / dayMilliseconds) * dayMilliseconds + dayOffset * dayMilliseconds;
  const feedVersion = new Date(generated).toISOString().slice(0, 10);
  return {
    operator: "skane", feedVersion, generatedAt: new Date(generated).toISOString(),
    expiresAt: new Date(generated + 7 * dayMilliseconds).toISOString(),
    sourceHashes: { regional: "a".repeat(64) },
    stations: [["902201", "740001", "Malmö Centralstation", 55.609, 13.001, "1"],
      ["902202", "740002", "Lund Centralstation", 55.705, 13.187, "2"]],
    services: [[feedVersion.replaceAll("-", "")]],
    trips: Array.from({ length: trips }, (_, i) => [String(121123100 + i), "1231", 0,
      [[0, 1, 3_600, 3_600], [1, 2, 7_200, 7_200]]] as const),
  };
}

function request(body: BodyInit = JSON.stringify(index()), headers: HeadersInit = {}, method = "POST"): IncomingRequest {
  return new Request(`https://watcher.test${path}`, { method, ...(method === "GET" ? {} : { body }), headers: {
    authorization: `Bearer ${secret}`, "content-type": "application/json",
    ...Object.fromEntries(new Headers(headers)),
  } }) as IncomingRequest;
}

function send(input: IncomingRequest, configuredSecret: string | undefined = secret): Promise<Response> {
  const bindings = { ...env } as WorkerEnv;
  if (configuredSecret === undefined) delete bindings.RAIL_DATA_REFRESH_SECRET;
  else bindings.RAIL_DATA_REFRESH_SECRET = configuredSecret;
  return worker.fetch(input, bindings, createExecutionContext());
}

async function stored(): Promise<Map<string, unknown>> {
  return runInDurableObject(env.WATCHER.getByName("global"), (_instance, state) => state.storage.list({ prefix }));
}

beforeEach(async () => {
  await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
    const keys = [...(await state.storage.list({ prefix })).keys()];
    if (keys.length > 0) await state.storage.delete(keys);
  });
});

describe("authenticated rail timetable refresh", () => {
  it.each([
    ["wrong bearer", () => request(undefined, { authorization: "Bearer wrong" }), secret, 401],
    ["missing bearer", () => request(undefined, { authorization: "" }), secret, 401],
    ["oversized bearer", () => request(undefined, { authorization: "x".repeat(513) }), secret, 401],
    ["short configured secret", () => request(), "short", 503],
    ["wrong method", () => request(undefined, {}, "GET"), secret, 405],
    ["wrong media type", () => request(undefined, { "content-type": "text/plain" }), secret, 415],
    ["malformed JSON", () => request("{"), secret, 400],
    ["wrong operator", () => request(JSON.stringify({ ...index(), operator: "other" })), secret, 400],
  ] as const)("rejects %s without writing the index", async (_name, makeRequest, configured, status) => {
    expect((await send(makeRequest(), configured)).status).toBe(status);
    expect((await stored()).size).toBe(0);
  });

  it("fails closed when refresh credentials are not configured", async () => {
    const bindings = { ...env } as WorkerEnv;
    delete bindings.RAIL_DATA_REFRESH_SECRET;
    const response = await worker.fetch(request(), bindings, createExecutionContext());
    expect(response.status).toBe(503);
    expect((await stored()).size).toBe(0);
  });

  it("bounds streamed bytes even when content-length understates them", async () => {
    let remaining = maximumRegionalIndexBytes + 1;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (remaining === 0) { controller.close(); return; }
        const size = Math.min(65_536, remaining);
        controller.enqueue(new Uint8Array(size).fill(32));
        remaining -= size;
      },
    });
    expect((await send(request(body, { "content-length": "1" }))).status).toBe(413);
    expect((await stored()).size).toBe(0);
    expect((await send(request("{}", { "content-length": String(maximumRegionalIndexBytes + 1) }))).status).toBe(413);
    expect((await stored()).size).toBe(0);
  });

  it("rejects invalid UTF-8 and invalid references without replacing a stored index", async () => {
    const value = index();
    expect((await send(request(JSON.stringify(value)))).status).toBe(200);
    const before = await stored();
    expect((await send(request(new Uint8Array([0xff]).buffer))).status).toBe(400);
    const invalid = { ...value, trips: [["121123100", "1231", 0, [[0, 1, 3_600, 3_600], [2, 2, 7_200, 7_200]]]] };
    expect((await send(request(JSON.stringify(invalid)))).status).toBe(400);
    expect(await stored()).toEqual(before);
  });

  it("atomically stores and loads a multichunk refresh, then rejects an older version", async () => {
    const value = index(0, 1_600);
    const response = await send(request(JSON.stringify(value)));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ outcome: "stored", feedVersion: value.feedVersion });
    const records = await stored();
    const manifest = records.get(`${prefix}manifest`) as { count: number; hash: string; version: string };
    expect(manifest.count).toBeGreaterThan(1);
    expect(records.size).toBe(manifest.count + 1);
    expect(manifest.hash).toMatch(/^[a-f0-9]{64}$/u);
    expect(manifest.version).toBe(value.feedVersion);
    expect([...records].filter(([key]) => key.includes(":chunk:")).every(([, chunk]) =>
      typeof chunk === "string" && new TextEncoder().encode(chunk).length < 128 * 1_024)).toBe(true);
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const store = new RailIndexStore(state.storage);
      expect(await store.load()).toEqual(value);
      const source = new TrafiklabRegionalIndexSource({ bundledIndex: index(-1), loadIndex: () => store.load() });
      expect(await source.get()).toEqual(value);
    });
    const duplicate = await send(request(JSON.stringify(value)));
    expect(await duplicate.json()).toEqual({ outcome: "unchanged", feedVersion: value.feedVersion });
    expect(await stored()).toEqual(records);
    const older = await send(request(JSON.stringify(index(-1))));
    expect(older.status).toBe(409);
    expect(await stored()).toEqual(records);
  });

  it("rolls back every chunk on a storage abort and removes obsolete chunks on success", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const store = new RailIndexStore(state.storage);
      const previous = index(-1, 1_600), next = index();
      expect((await store.save(previous)).outcome).toBe("stored");
      const before = await state.storage.list({ prefix });
      const abortingStorage = new Proxy(state.storage, {
        get(target, property) {
          if (property === "transaction") return <T>(work: (transaction: DurableObjectTransaction) => Promise<T>) =>
            target.transaction(async (transaction) => {
              await work(transaction);
              throw new Error("refresh transaction aborted");
            });
          const value = Reflect.get(target, property);
          return typeof value === "function" ? value.bind(target) : value;
        },
      });
      await expect(new RailIndexStore(abortingStorage).save(next)).rejects.toThrow("refresh transaction aborted");
      expect(await state.storage.list({ prefix })).toEqual(before);
      expect(await store.load()).toEqual(previous);
      expect((await store.save(next)).outcome).toBe("stored");
      expect(await store.load()).toEqual(next);
      expect((await state.storage.list({ prefix })).size).toBe(2);
    });
  });

  it("refuses to load missing or modified chunks", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const store = new RailIndexStore(state.storage);
      await store.save(index(0, 1_600));
      await state.storage.delete(`${prefix}chunk:1`);
      expect(await store.load()).toBeNull();
      await store.save(index());
      await state.storage.put(`${prefix}chunk:0`, "{}");
      expect(await store.load()).toBeNull();
    });
  });
});

import { env, runInDurableObject } from "cloudflare:test";
import { beforeEach, afterEach, expect, it, vi } from "vitest";
import worker, { type MainlineGTFSMaintenanceEnv } from "../src/cloudflare/mainline-gtfs-maintenance-worker.js";
import { taiwanArchive } from "../worker-tests/fixtures/taiwan-gtfs.js";
import { korailArchive } from "../worker-tests/fixtures/korail-gtfs.js";

const bindings = env as unknown as MainlineGTFSMaintenanceEnv;
const secret = "mainline-gtfs-test-refresh-secret-32-characters";
type Incoming = Parameters<typeof worker.fetch>[0];
const request = (path: string, token = secret) => new Request(`https://maintenance.test${path}`, {
  method: path.endsWith("refresh") ? "POST" : "GET", headers: { authorization: `Bearer ${token}` },
}) as Incoming;
beforeEach(async () => {
  vi.useFakeTimers({ toFake: ["Date"] }); vi.setSystemTime(new Date("2026-11-14T00:00:00Z"));
  vi.stubGlobal("fetch",vi.fn(async () => { throw new Error("Unexpected request"); }));
  await runInDurableObject(bindings.GTFS_MAINTENANCE.getByName("TW"),async (_,state) => state.storage.deleteAll());
  await runInDurableObject(bindings.GTFS_MAINTENANCE.getByName("KR"),async (_,state) => state.storage.deleteAll());
});
afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); });

it("publishes only the compact allowlisted timetable and reserves daily attempts across restarts",async () => {
  vi.mocked(fetch).mockImplementation(async (input,init) => {
    const url = String(input);
    if (url.startsWith("https://github.com/jcanizalez/")) return new Response(taiwanArchive());
    expect(url).toBe("https://roundhouse-api.example.invalid/internal/rail-data/mainline-gtfs/tw");
    expect(new Headers(init?.headers).get("authorization")).toBe(`Bearer ${secret}`);
    const body = JSON.parse(init?.body as string);
    expect(body.trips.map((t: {agency: string}) => t.agency).sort()).toEqual(["THSR","TRA"]);
    expect(JSON.stringify(body)).not.toContain("fare_products");
    return Response.json({ outcome: "stored", country: "TW", compiledAt: body.compiledAt, sourceHash: body.sourceHash });
  });
  expect(await (await worker.fetch(request("/tw/refresh"),bindings)).json()).toMatchObject({ country: "TW", outcome: "stored", trips: 2, stations: 4 });
  const before = vi.mocked(fetch).mock.calls.length;
  await worker.fetch(request("/tw/refresh"),bindings);
  expect(vi.mocked(fetch).mock.calls.length).toBe(before);
  expect(await (await worker.fetch(request("/tw/health"),bindings)).json()).toMatchObject({ outcome: "stored" });
});
it("authenticates before downloads, contains failure details, and preserves the previous publication",async () => {
  expect((await worker.fetch(request("/tw/refresh","wrong"),bindings)).status).toBe(401);
  expect(vi.mocked(fetch).mock.calls).toHaveLength(0);
  vi.mocked(fetch).mockRejectedValue(new Error("secret-URL?token=private"));
  const result = await worker.fetch(request("/tw/refresh"),bindings);
  const text = await result.text();
  expect(JSON.parse(text)).toMatchObject({ country: "TW", outcome: "failed" });
  expect(text).not.toMatch(/secret-URL|private|token=/u);
  await worker.fetch(request("/tw/refresh"),bindings);
  expect(vi.mocked(fetch).mock.calls).toHaveLength(1);
});
it("runs the same staged publication path for Korail with its original realtime trip IDs",async () => {
  vi.mocked(fetch).mockImplementation(async (input,init) => {
    if (String(input)==="https://mkuran.pl/gtfs/korail.zip") return new Response(korailArchive());
    expect(String(input)).toBe("https://roundhouse-api.example.invalid/internal/rail-data/mainline-gtfs/kr");
    const index=JSON.parse(init?.body as string);
    expect(index.trips.map((t:{id:string})=>t.id)).toEqual(["1","2"]);
    return Response.json({outcome:"stored",country:"KR",compiledAt:index.compiledAt,sourceHash:index.sourceHash});
  });
  expect(await (await worker.fetch(request("/kr/refresh"),bindings)).json()).toMatchObject({country:"KR",outcome:"stored",stations:2,trips:2,phase:"completed"});
});
it("runs at the scheduled publication window even after a manual check earlier in the same UTC day",async () => {
  vi.mocked(fetch).mockImplementation(async (input,init) => {
    if (String(input).startsWith("https://github.com/")) return new Response(taiwanArchive());
    const index=JSON.parse(init?.body as string);
    return Response.json({outcome:"stored",country:"TW",compiledAt:index.compiledAt,sourceHash:index.sourceHash});
  });
  vi.setSystemTime(new Date("2026-11-14T15:00:00Z"));
  await worker.fetch(request("/tw/refresh"),bindings);
  vi.setSystemTime(new Date("2026-11-14T20:10:00Z"));
  expect(await (await worker.fetch(request("/tw/refresh"),bindings)).json()).toMatchObject({
    outcome:"stored",startedAt:"2026-11-14T20:10:00.000Z",attemptsToday:1,
  });
});
it("allows one explicitly identified interrupted run to recover after its timeout",async () => {
  const object = bindings.GTFS_MAINTENANCE.getByName("TW");
  await runInDurableObject(object,async (_,state) => state.storage.put("attempt",{
    country: "TW", startedAt: "2026-11-14T00:00:00.000Z", completedAt: null, outcome: "running",
    attemptsToday: 1, stations: 0, trips: 0, downloadBytes: 0, sourceHash: null,
  }));
  vi.setSystemTime(new Date("2026-11-14T00:03:00Z"));
  vi.mocked(fetch).mockImplementation(async (input,init) => {
    if (String(input).startsWith("https://github.com/")) return new Response(taiwanArchive());
    const index = JSON.parse(init?.body as string);
    return Response.json({ outcome: "stored", country: "TW", compiledAt: index.compiledAt, sourceHash: index.sourceHash });
  });
  const retry = new Request("https://maintenance.test/tw/refresh",{ method: "POST", headers: {
    authorization: `Bearer ${secret}`, "content-type": "application/json",
  },body: JSON.stringify({ retryFailedAttemptAt: "2026-11-14T00:00:00.000Z" }) }) as Incoming;
  expect(await (await worker.fetch(retry,bindings)).json()).toMatchObject({ outcome: "stored", attemptsToday: 2 });
  expect(await object.begin("TW","2026-11-14T00:03:00.000Z")).toMatchObject({ outcome: "retry-rejected" });
});

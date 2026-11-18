import { env, runInDurableObject, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { StopSnapshot, TripSnapshot } from "../src/domain/snapshot.js";
import type { TrainTrackerWatcher } from "../src/cloudflare/watcher-object.js";

const stub = () => env.WATCHER.getByName("global");
const iso = (minutes: number) => new Date(Date.now() + minutes * 60_000).toISOString();
const base = { id:"us:amtraker:171-18", source:"amtraker" as const, nativeId:"171-18", serviceDate:"2026-11-18" };
function snapshot(overrides: Partial<StopSnapshot> = {}): TripSnapshot {
  const stop: StopSnapshot = { stationId:"us:amtraker:BAL", stationName:"Baltimore Penn", sequence:2, countryCode:"US", latitude:39.3, longitude:-76.6,
    scheduledArrival:iso(30), expectedArrival:iso(42), scheduledDeparture:iso(33), expectedDeparture:null, plannedPlatform:"1",
    expectedPlatform:"3", platformSource:"Amtrak", platformObservedAt:iso(-3), passed:false, cancelled:false, ...overrides };
  return { ...base, operatorName:"Amtrak", product:"Northeast Regional 171", headsign:"New York Penn",
    fetchedAt:iso(0), alertIds:["irrelevant"], stops:[{ ...stop, stationId:"origin", stationName:"Washington", sequence:1 },
      stop, { ...stop, stationId:"terminus", stationName:"New York Penn", sequence:3 }], positions:[{ latitude:39.2,
        longitude:-76.5, heading:null, source:"real", confidence:1, asOf:iso(-1), provider:"Amtraker" }] };
}

async function setSnapshot(value: TripSnapshot | null) {
  await runInDurableObject(stub(), async (instance) => {
    (instance as TrainTrackerWatcher).snapshot = async () => {
      if (value === null) throw new Error("test feed outage");
      return structuredClone(value);
    };
  });
}

const note = 'East exit by the clock <b>under the sign</b>';
const input = { trip:base, stationId:"us:amtraker:BAL", sequence:2, timeZone:"America/New_York", note };
const post = (path: string, value: unknown) => SELF.fetch("https://roundhouse.test" + path,
  { method:"POST", headers:{ "content-type":"application/json" }, body:JSON.stringify(value) });

describe("private arrival boards through the public Worker", () => {
  it("creates the selected call, refreshes live, falls back, settles arrival and retires the encrypted record", async () => {
    await setSnapshot(snapshot());
    const created = await post("/v1/arrival-boards", input);
    expect(created.status).toBe(201);
    const link = new URL((await created.json<{ url:string }>()).url);
    expect(link.pathname).toBe("/meet"); expect(link.search).toBe("");
    const token = link.hash.slice(1); expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/u);
    expect((await SELF.fetch(link)).headers.get("referrer-policy")).toBe("no-referrer");
    expect(await (await SELF.fetch(link)).text()).not.toContain(note);
    const status = () => post("/v1/arrival-boards/status", { token });
    const initial = await (await status()).json<Record<string, unknown>>();
    expect(initial).toMatchObject({ station:"Baltimore Penn", service:"Northeast Regional 171", basis:"estimated", delayMinutes:12, note });
    expect(Object.keys(initial).sort()).toEqual(["basis","checkedAt","credit","delayMinutes","expiresAt","note","reportedAt","scheduled","service","station","time","timeZone","updatesAvailable"].sort());
    expect(JSON.stringify(initial)).not.toMatch(/New York Penn|Washington|latitude|longitude|origin|booking|passenger/iu);
    await runInDurableObject(stub(), async (_instance, state) => {
      const row = state.storage.sql.exec("SELECT * FROM arrival_boards LIMIT 1").one();
      expect(JSON.stringify(row)).not.toContain(note);
      expect(JSON.stringify(row)).not.toContain(token);
      expect(JSON.stringify(row)).not.toContain("Baltimore");
    });
    await setSnapshot(snapshot({expectedArrival:iso(53)}));
    expect(await (await status()).json()).toMatchObject({ basis:"estimated", delayMinutes:23 });
    await setSnapshot(null);
    expect(await (await status()).json()).toMatchObject({ basis:"scheduled", updatesAvailable:false, delayMinutes:null, checkedAt:null });
    const reported = iso(-2);
    await setSnapshot(snapshot({arrivalObservedAt:reported}));
    const actual = await (await status()).json<{expiresAt:string}>();
    expect(actual).toMatchObject({basis:"arrived", reportedAt:reported});
    expect(Date.parse(actual.expiresAt)).toBe(Date.parse(reported) + 60 * 60_000);
    await setSnapshot(null);
    expect(await (await status()).json()).toMatchObject({basis:"arrived", reportedAt:reported});
    await runInDurableObject(stub(), async (_instance, state) => {
      state.storage.sql.exec("UPDATE arrival_boards SET expires = ?", Date.now() - 1000);
    });
    const closed = await status();
    expect(closed.status).toBe(410); expect(await closed.text()).not.toContain(note);
    await stub().pruneArrivalBoards();
    await runInDurableObject(stub(), async (_instance, state) => {
      expect(state.storage.sql.exec("SELECT id FROM arrival_boards").toArray()).toEqual([]);
    });
  });

  it("rejects occurrence mismatches, finished trains, invalid zones and malformed capabilities", async () => {
    await setSnapshot(snapshot());
    expect((await post("/v1/arrival-boards", {...input, sequence:3})).status).toBe(422);
    expect((await post("/v1/arrival-boards", {...input, timeZone:"Imaginary/Station"})).status).toBe(400);
    expect((await post("/v1/arrival-boards", {...input, note:"a".repeat(181)})).status).toBe(400);
    await setSnapshot(snapshot({arrivalObservedAt:iso(-1)}));
    expect((await post("/v1/arrival-boards", input)).status).toBe(410);
    expect((await post("/v1/arrival-boards/status", {token:"a".repeat(43)})).status).toBe(410);
    expect((await post("/v1/arrival-boards/status", {token:"generic.trip.signature"})).status).toBe(410);
  });
});

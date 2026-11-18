import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { SQLiteSrbijaVozSnapshotStore } from "../src/cloudflare/srbijavoz-snapshot-store.js";
import type { TripSnapshot } from "../src/domain/snapshot.js";

const snapshot: TripSnapshot = {
  id: "rs:srbijavoz:v1_2026-11-13_1181_12546_16052_16807_1154",
  source: "srbijavoz", nativeId: "v1_2026-11-13_1181_12546_16052_16807_1154", serviceDate: "2026-11-13",
  operatorName: "Srbija Voz", product: "IC 12546", headsign: "Subotica",
  fetchedAt: "2026-11-13T09:20:00Z", stops: [], alertIds: [],
};

describe("durable official Serbian timetables", () => {
  it("preserves the original source timestamp across store reconstruction", async () => {
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const original = new SQLiteSrbijaVozSnapshotStore(state.storage.sql, () => Date.parse("2026-11-13T09:20:00Z"));
      await original.put(snapshot.id, snapshot);
      const reconstructed = new SQLiteSrbijaVozSnapshotStore(state.storage.sql, () => Date.parse("2026-11-13T13:00:00Z"));
      expect(await reconstructed.get(snapshot.id)).toEqual(snapshot);
      expect(await reconstructed.get(snapshot.id + "-different-train")).toBeUndefined();
    });
  });

  it("does not return expired schedules and prunes them on later writes", async () => {
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      let now = Date.parse("2026-11-13T09:20:00Z");
      const store = new SQLiteSrbijaVozSnapshotStore(state.storage.sql, () => now);
      await store.put(snapshot.id, snapshot);
      now = Date.parse("2026-11-16T00:00:00Z");
      expect(await store.get(snapshot.id)).toBeUndefined();
      const later = { ...snapshot, id: "new-day", serviceDate: "2026-11-16" };
      await store.put(later.id, later);
      expect(state.storage.sql.exec("SELECT cache_key FROM srbijavoz_schedules").toArray())
        .toEqual([{ cache_key: "new-day" }]);
    });
  });
});

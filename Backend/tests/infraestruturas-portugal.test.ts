import { describe, expect, it, vi } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { InfraestruturasPortugalOverlay } from "../src/providers/infraestruturas-portugal.js";

const now = new Date("2026-07-21T16:50:00.000Z");

function snapshot(): TripSnapshot {
  return {
    id: "pt-127",
    source: "transitous",
    nativeId: "20260721_17:00_pt-Comboios-de-Portugal(CP)_127_20251214",
    serviceDate: "2026-07-21",
    operatorName: "CP - Comboios de Portugal",
    product: "AP",
    headsign: "Porto Campanha",
    fetchedAt: now.toISOString(),
    alertIds: [],
    stops: [
      {
        stationId: "eu:transitous:pt-Comboios-de-Portugal(CP)_94_30007",
        stationName: "Lisboa Santa Apolonia",
        countryCode: "PT",
        latitude: 38.71584,
        longitude: -9.120748,
        sequence: 1,
        scheduledArrival: null,
        scheduledDeparture: "2026-07-21T17:00:00.000Z",
        expectedArrival: null,
        expectedDeparture: "2026-07-21T17:00:00.000Z",
        plannedPlatform: null,
        expectedPlatform: null,
        platformSource: null,
        platformObservedAt: null,
        cancelled: false,
        passed: false,
      },
      {
        stationId: "eu:transitous:pt-Comboios-de-Portugal(CP)_94_31039",
        stationName: "Lisboa Oriente",
        countryCode: "PT",
        latitude: 38.767757,
        longitude: -9.099094,
        sequence: 2,
        scheduledArrival: "2026-07-21T17:08:00.000Z",
        scheduledDeparture: "2026-07-21T17:09:00.000Z",
        expectedArrival: "2026-07-21T17:08:00.000Z",
        expectedDeparture: "2026-07-21T17:09:00.000Z",
        plannedPlatform: null,
        expectedPlatform: null,
        platformSource: null,
        platformObservedAt: null,
        cancelled: false,
        passed: false,
      },
    ],
  };
}

function stationPage(note: string): string {
  return `<table><tbody>
    <tr><td>17:00</td><td><a href="horarios?nComboio=127&amp;data=2026-07-21">127</a></td>
    <td>ALFA</td><td>Lisboa</td><td>Porto</td><td>CP LONGO CURSO</td><td>${note}</td></tr>
  </tbody></table>`;
}

describe("InfraestruturasPortugalOverlay", () => {
  it("maps public IP delay observations onto the next stops and caches them", async () => {
    const fetcher = vi.fn<typeof fetch>().mockImplementation(async () =>
      new Response(stationPage("Circula com atraso de 12 min."))
    );
    const overlay = new InfraestruturasPortugalOverlay("https://ip.test", fetcher, () => now);

    const updates = await overlay.platformUpdates(snapshot());
    const alerts = await overlay.tripAlertIds(snapshot());

    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(fetcher.mock.calls[0]?.[0]).toBe("https://ip.test/estacoes?estacaoId=9430007");
    expect(updates).toHaveLength(1);
    expect(updates[0]).toMatchObject({
      stopSequence: 1,
      expectedDeparture: "2026-07-21T17:12:00.000Z",
      cancelled: false,
    });
    expect(alerts).toHaveLength(1);
  });

  it("recognizes a suppressed train as cancelled", async () => {
    const fetcher = vi.fn<typeof fetch>().mockImplementation(async () =>
      new Response(stationPage("Comboio suprimido."))
    );
    const overlay = new InfraestruturasPortugalOverlay("https://ip.test", fetcher, () => now);

    await expect(overlay.platformUpdates(snapshot())).resolves.toEqual(expect.arrayContaining([
      expect.objectContaining({ stopSequence: 1, cancelled: true }),
    ]));
  });

  it("serves API snapshots from cache without blocking on a cold IP page", async () => {
    const fetcher = vi.fn<typeof fetch>().mockImplementation(async () =>
      new Response(stationPage("Circula com atraso de 7 min."))
    );
    const overlay = new InfraestruturasPortugalOverlay("https://ip.test", fetcher, () => now);
    const cached = overlay.cachedOverlay();

    await expect(cached.platformUpdates(snapshot())).resolves.toEqual([]);
    expect(fetcher).not.toHaveBeenCalled();

    await overlay.platformUpdates(snapshot());
    await expect(cached.platformUpdates(snapshot())).resolves.toEqual([
      expect.objectContaining({
        stopSequence: 1,
        expectedDeparture: "2026-07-21T17:07:00.000Z",
      }),
    ]);
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it("does not query IP for a non-CP trip", async () => {
    const fetcher = vi.fn<typeof fetch>();
    const overlay = new InfraestruturasPortugalOverlay("https://ip.test", fetcher, () => now);
    const value = snapshot();
    value.nativeId = "20260721_17:00_pt-Fertagus_127";

    await expect(overlay.platformUpdates(value)).resolves.toEqual([]);
    expect(fetcher).not.toHaveBeenCalled();
  });
});

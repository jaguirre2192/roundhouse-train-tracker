import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { RenfePlatformOverlay } from "../src/providers/renfe.js";

function snapshot(): TripSnapshot {
  return {
    id: "eu:transitous:20260721_17:04_es-Cercanías-Renfe_1099M21244C10",
    source: "transitous",
    nativeId: "20260721_17:04_es-Cercanías-Renfe_1099M21244C10",
    serviceDate: "2026-07-21",
    operatorName: "Renfe Cercanías",
    product: "C10",
    headsign: "Villalba",
    fetchedAt: "2026-07-21T10:00:00.000Z",
    alertIds: [],
    stops: [{
      stationId: "eu:transitous:es-Cercanías-Renfe_18000",
      stationName: "Madrid-Atocha Cercanías",
      countryCode: "ES",
      latitude: 40.40662,
      longitude: -3.689439,
      sequence: 1,
      scheduledArrival: "2026-07-21T10:04:00.000Z",
      scheduledDeparture: "2026-07-21T10:05:00.000Z",
      expectedArrival: "2026-07-21T10:04:00.000Z",
      expectedDeparture: "2026-07-21T10:05:00.000Z",
      plannedPlatform: null,
      expectedPlatform: null,
      platformSource: null,
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }, {
      stationId: "eu:transitous:es-Cercanías-Renfe_17000",
      stationName: "Madrid-Chamartín-Clara Campoamor",
      countryCode: "ES",
      latitude: 40.472,
      longitude: -3.682,
      sequence: 2,
      scheduledArrival: "2026-07-21T10:20:00.000Z",
      scheduledDeparture: null,
      expectedArrival: "2026-07-21T10:20:00.000Z",
      expectedDeparture: null,
      plannedPlatform: null,
      expectedPlatform: null,
      platformSource: null,
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }],
  };
}

describe("Renfe official realtime overlay", () => {
  it("joins platforms, positions, delays, skipped stops, and service alerts", async () => {
    const overlay = new RenfePlatformOverlay(
      "https://example.test/vehicles.json",
      async (input) => {
        const path = new URL(String(input)).pathname;
        if (path.endsWith("/vehicles.json")) {
          return Response.json({
            header: { timestamp: "1784628010" },
            entity: [{ vehicle: {
              trip: { tripId: "1099M21244C10" },
              timestamp: "1784628010",
              stopId: "18000",
              position: { latitude: 40.41, longitude: -3.69, bearing: 25 },
              vehicle: { id: "21244", label: "C10-21244-PLATF.(8)" },
            } }],
          });
        }
        if (path.endsWith("/trip-updates.json")) {
          return Response.json({
            header: { timestamp: "1784628015" },
            entity: [{ tripUpdate: {
              trip: { tripId: "1099M21244C10", scheduleRelationship: "SCHEDULED" },
              delay: 420,
              stopTimeUpdate: [{
                stopId: "18000",
                departure: { delay: 420 },
              }, {
                stopId: "17000",
                scheduleRelationship: "SKIPPED",
              }],
            } }],
          });
        }
        return Response.json({
          header: { timestamp: "1784628018" },
          entity: [{
            id: "AVISO_C10",
            alert: {
              activePeriod: [{ start: "1784627900", end: "1784629000" }],
              informedEntity: [{ routeId: "10T0019C10" }],
            },
          }],
        });
      },
      () => new Date("2026-07-21T10:00:20.000Z"),
      {
        tripUpdateFeedUrls: ["https://example.test/trip-updates.json"],
        alertFeedUrl: "https://example.test/alerts.json",
      },
    );

    const updates = [...await overlay.timingOverlay.platformUpdates(snapshot()), ...await overlay.platformUpdates(snapshot())];
    const position = await overlay.positionUpdates(snapshot());
    const alertIds = await overlay.tripAlertIds(snapshot());

    expect(updates).toContainEqual(expect.objectContaining({
      stationId: "eu:transitous:es-Cercanías-Renfe_18000",
      expectedPlatform: "8",
    }));
    expect(updates).toContainEqual(expect.objectContaining({
      stationId: "eu:transitous:es-Cercanías-Renfe_18000",
      expectedDeparture: "2026-07-21T10:12:00.000Z",
    }));
    expect(updates).toContainEqual(expect.objectContaining({
      stationId: "eu:transitous:es-Cercanías-Renfe_17000",
      expectedArrival: "2026-07-21T10:27:00.000Z",
      cancelled: true,
    }));
    expect(position[0]).toMatchObject({
      latitude: 40.41,
      longitude: -3.69,
      heading: 25,
      source: "real",
      provider: "Renfe GTFS-RT",
    });
    expect(alertIds).toEqual(["renfe-alert-AVISO_C10"]);
  });

  it("marks every upcoming stop when Renfe cancels the whole trip", async () => {
    const overlay = new RenfePlatformOverlay(
      "https://example.test/vehicles.json",
      async (input) => new URL(String(input)).pathname.endsWith("/trip-updates.json")
        ? Response.json({
          header: { timestamp: "1784628015" },
          entity: [{ tripUpdate: {
            trip: { tripId: "1099M21244C10", scheduleRelationship: "CANCELED" },
          } }],
        })
        : Response.json({ header: { timestamp: "1784628010" }, entity: [] }),
      () => new Date("2026-07-21T10:00:20.000Z"),
      { tripUpdateFeedUrls: ["https://example.test/trip-updates.json"] },
    );

    const updates = [...await overlay.timingOverlay.platformUpdates(snapshot()), ...await overlay.platformUpdates(snapshot())];

    expect(updates.filter((value) => value.cancelled)).toHaveLength(2);
  });

  it("does not attach a colliding Renfe number or unmatched platform to another operator", async () => {
    const overlay = new RenfePlatformOverlay(
      "https://example.test/vehicles.json",
      async () => Response.json({
        header: { timestamp: "1784628010" },
        entity: [{ vehicle: {
          trip: { tripId: "21244" },
          timestamp: "1784628010",
          stopId: "99999",
          vehicle: { id: "21244", label: "C10-21244-PLATF.(8)" },
        } }],
      }),
      () => new Date("2026-07-21T10:00:20.000Z"),
    );
    const otherOperator = {
      ...snapshot(),
      operatorName: "OUIGO España",
      nativeId: "20260721_es-Ouigo_21244",
    };

    await expect(overlay.platformUpdates(otherOperator)).resolves.toEqual([]);
  });
});

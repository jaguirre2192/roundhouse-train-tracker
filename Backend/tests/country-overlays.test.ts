import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { IRailPlatformOverlay } from "../src/providers/irail.js";
import { RenfePlatformOverlay } from "../src/providers/renfe.js";
import { DigitrafficPlatformOverlay } from "../src/providers/digitraffic.js";
import { EnturPlatformOverlay } from "../src/providers/entur.js";

function trip(countryCode: string, product: string, nativeId: string, stationId: string): TripSnapshot {
  return {
    id: `eu:transitous:${nativeId}`,
    source: "transitous",
    nativeId,
    serviceDate: "2026-07-20",
    operatorName: countryCode === "ES" ? "Renfe" : "Rail operator",
    product,
    headsign: "Destination",
    fetchedAt: "2026-07-20T19:18:00.000Z",
    alertIds: [],
    stops: [{
      stationId,
      stationName: countryCode === "BE" ? "Bruxelles-Midi"
        : countryCode === "FI" ? "Helsinki"
        : countryCode === "NO" ? "Oslo S"
        : "Madrid-Puerta de Atocha",
      countryCode,
      latitude: 0,
      longitude: 0,
      sequence: 1,
      scheduledArrival: null,
      scheduledDeparture: "2026-07-20T19:20:00.000Z",
      expectedArrival: null,
      expectedDeparture: "2026-07-20T19:20:00.000Z",
      plannedPlatform: null,
      expectedPlatform: null,
      platformSource: null,
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }],
  };
}

describe("country platform overlays", () => {
  it("extracts an iRail platform for a matching Belgian departure", async () => {
    const fixture = await readFile(new URL("../../Packages/TrainTrackerCore/Tests/TrainTrackerCoreTests/Fixtures/IRail/liveboard.json", import.meta.url));
    const overlay = new IRailPlatformOverlay(
      "https://example.test",
      async () => new Response(fixture, { status: 200 }),
      () => new Date("2026-07-20T19:18:00.000Z"),
    );
    const value = await overlay.platformUpdates(trip("BE", "IC 1234", "be-test-1234", "eu:transitous:be-test-brussels"));
    expect(value[0]).toMatchObject({ expectedPlatform: "5", source: "iRail" });
  });

  it("extracts a Renfe platform from a matching vehicle label", async () => {
    const fixture = await readFile(new URL("../../Packages/TrainTrackerCore/Tests/TrainTrackerCoreTests/Fixtures/RenfeRealtime/vehicle_positions.json", import.meta.url));
    const overlay = new RenfePlatformOverlay(
      "https://example.test",
      async () => new Response(fixture, { status: 200 }),
      () => new Date("2026-07-20T19:14:15.000Z"),
    );
    const value = await overlay.platformUpdates({ ...trip("ES", "AVE 23573", "3098L23573C1", "eu:transitous:es-test-51003"), serviceDate: "2026-07-20" });
    expect(value[0]).toMatchObject({ expectedPlatform: "8", source: "Renfe GTFS-RT" });
  });

  it("extracts an official Digitraffic commercial track for Finland", async () => {
    const requests: Request[] = [];
    const overlay = new DigitrafficPlatformOverlay(
      "https://example.test/api/v1",
      async (input, init) => {
        requests.push(new Request(input, init));
        const path = new URL(String(input)).pathname;
        if (path.endsWith("/metadata/stations")) {
          return Response.json([{
            passengerTraffic: true,
            stationName: "Helsinki asema",
            stationShortCode: "HKI",
          }]);
        }
        return Response.json([{
          trainNumber: 6,
          departureDate: "2026-07-20",
          commuterLineID: "",
          timeTableRows: [{
            stationShortCode: "HKI",
            type: "DEPARTURE",
            scheduledTime: "2026-07-20T19:20:00.000Z",
            liveEstimateTime: "2026-07-20T19:22:00.000Z",
            actualTime: null,
            commercialTrack: "10",
            cancelled: false,
          }],
        }]);
      },
      () => new Date("2026-07-20T19:18:00.000Z"),
    );

    const value = await overlay.platformUpdates(trip("FI", "IC 6", "fi-test-6", "eu:transitous:fi-test-helsinki"));

    expect(value[0]).toMatchObject({ expectedPlatform: "10", source: "Fintraffic Digitraffic" });
    expect(requests.every((request) => request.headers.get("digitraffic-user") === "TrainTracker/0.2")).toBe(true);
    expect(requests.every((request) => request.headers.get("accept-encoding") === "gzip")).toBe(true);
  });

  it("extracts an Entur realtime quay for Norway", async () => {
    const requests: Request[] = [];
    const overlay = new EnturPlatformOverlay(
      "https://example.test/geocoder",
      "https://example.test/graphql",
      async (input, init) => {
        const request = new Request(input, init);
        requests.push(request);
        if (request.url.includes("geocoder")) {
          return Response.json({ features: [{ properties: {
            id: "NSR:StopPlace:59872",
            names: { default: "Oslo S" },
            address: { countryCode: "no" },
          } }] });
        }
        return Response.json({ data: { stopPlace: { estimatedCalls: [{
          date: "2026-07-20",
          aimedArrivalTime: "2026-07-20T19:20:00.000Z",
          aimedDepartureTime: "2026-07-20T19:20:00.000Z",
          expectedArrivalTime: "2026-07-20T19:21:00.000Z",
          expectedDepartureTime: "2026-07-20T19:21:00.000Z",
          realtime: true,
          cancellation: false,
          destinationDisplay: { frontText: "Dal" },
          quay: { publicCode: "10" },
          serviceJourney: { id: "VYG:ServiceJourney:1453_443409-R" },
        }] } } });
      },
      () => new Date("2026-07-20T19:18:00.000Z"),
    );

    const snapshot = trip("NO", "R13", "20260720_21:20_no-Entur_VYG:ServiceJourney:1453_443409-R", "eu:transitous:no-test-oslo");
    snapshot.serviceDate = "2026-07-20";
    const value = await overlay.platformUpdates(snapshot);

    expect(value[0]).toMatchObject({ expectedPlatform: "10", source: "Entur" });
    expect(value[0]).toMatchObject({
      expectedArrival: undefined,
      expectedDeparture: "2026-07-20T19:21:00.000Z",
      cancelled: false,
    });
    expect(requests.every((request) => request.headers.get("et-client-name") === "traintracker-app")).toBe(true);
  });

  it("preserves official iRail delay and cancellation observations", async () => {
    const overlay = new IRailPlatformOverlay(
      "https://example.test",
      async () => Response.json({
        timestamp: "1784574900",
        departures: { departure: [{
          time: "1784575200",
          delay: "420",
          canceled: "1",
          vehicle: "BE.NMBS.IC1234",
          vehicleinfo: { shortname: "IC 1234", number: "1234" },
          platform: "5",
        }] },
      }),
      () => new Date("2026-07-20T19:18:00.000Z"),
    );

    const value = await overlay.platformUpdates(trip("BE", "IC 1234", "be-test-1234", "eu:transitous:be-test-brussels"));

    expect(value[0]).toMatchObject({
      expectedPlatform: "5",
      expectedDeparture: "2026-07-20T19:27:00.000Z",
      cancelled: true,
    });
  });

  it("preserves official Digitraffic expected time and cancellation fields", async () => {
    const overlay = new DigitrafficPlatformOverlay(
      "https://example.test/api/v1",
      async (input) => {
        if (new URL(String(input)).pathname.endsWith("/metadata/stations")) {
          return Response.json([{ passengerTraffic: true, stationName: "Helsinki asema", stationShortCode: "HKI" }]);
        }
        return Response.json([{
          trainNumber: 6,
          departureDate: "2026-07-20",
          commuterLineID: "",
          timeTableRows: [{
            stationShortCode: "HKI",
            type: "DEPARTURE",
            scheduledTime: "2026-07-20T19:20:00.000Z",
            liveEstimateTime: "2026-07-20T19:28:00.000Z",
            actualTime: null,
            commercialTrack: "10",
            cancelled: true,
          }],
        }]);
      },
      () => new Date("2026-07-20T19:18:00.000Z"),
    );

    const value = await overlay.platformUpdates(trip("FI", "IC 6", "fi-test-6", "eu:transitous:fi-test-helsinki"));

    expect(value[0]).toMatchObject({
      expectedPlatform: "10",
      expectedDeparture: "2026-07-20T19:28:00.000Z",
      cancelled: true,
    });
  });
});

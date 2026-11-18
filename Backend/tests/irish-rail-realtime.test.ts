import { describe, expect, it } from "vitest";
import { diffSnapshots } from "../src/domain/events.js";
import { defaultPushPreferences, type TripSnapshot } from "../src/domain/snapshot.js";
import { IrishRailRealtimeOverlay } from "../src/providers/irish-rail-realtime.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";

function trip(): TripSnapshot {
  return {
    id: "eu:transitous:20260721_19:00_ie-transport-for-ireland_5703_4692",
    source: "transitous",
    nativeId: "20260721_19:00_ie-transport-for-ireland_5703_4692",
    serviceDate: "2026-07-21",
    operatorName: "Iarnród Éireann / Irish Rail",
    product: "InterCity",
    headsign: "Cork (Kent)",
    fetchedAt: "2026-07-21T17:55:00.000Z",
    alertIds: [],
    stops: [
      {
        stationId: "eu:transitous:ie-transport-for-ireland_8220IR0132",
        stationName: "Dublin Heuston",
        countryCode: "IE",
        latitude: 53.3464,
        longitude: -6.2935,
        sequence: 1,
        scheduledArrival: null,
        scheduledDeparture: "2026-07-21T18:00:00.000Z",
        expectedArrival: null,
        expectedDeparture: "2026-07-21T18:00:00.000Z",
        plannedPlatform: null,
        expectedPlatform: null,
        platformSource: null,
        platformObservedAt: null,
        cancelled: false,
        passed: false,
      },
      {
        stationId: "eu:transitous:ie-transport-for-ireland_8280IR0068",
        stationName: "Portlaoise",
        countryCode: "IE",
        latitude: 53.036,
        longitude: -7.301,
        sequence: 2,
        scheduledArrival: "2026-07-21T18:46:00.000Z",
        scheduledDeparture: "2026-07-21T18:48:00.000Z",
        expectedArrival: "2026-07-21T18:46:00.000Z",
        expectedDeparture: "2026-07-21T18:48:00.000Z",
        plannedPlatform: null,
        expectedPlatform: null,
        platformSource: null,
        platformObservedAt: null,
        cancelled: false,
        passed: false,
      },
      {
        stationId: "eu:transitous:ie-transport-for-ireland_8370IR0126",
        stationName: "Cork (Kent)",
        countryCode: "IE",
        latitude: 51.902,
        longitude: -8.459,
        sequence: 3,
        scheduledArrival: "2026-07-21T20:48:00.000Z",
        scheduledDeparture: null,
        expectedArrival: "2026-07-21T20:48:00.000Z",
        expectedDeparture: null,
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

const stationsXML = `
  <ArrayOfObjStation>
    <objStation>
      <StationDesc>Dublin Heuston</StationDesc><StationLatitude>53.3464</StationLatitude>
      <StationLongitude>-6.2935</StationLongitude><StationCode>HSTON</StationCode>
    </objStation>
    <objStation>
      <StationDesc>Portlaoise</StationDesc><StationLatitude>53.036</StationLatitude>
      <StationLongitude>-7.301</StationLongitude><StationCode>PTLSE</StationCode>
    </objStation>
    <objStation>
      <StationDesc>Cork</StationDesc><StationLatitude>51.902</StationLatitude>
      <StationLongitude>-8.459</StationLongitude><StationCode>CORK</StationCode>
    </objStation>
  </ArrayOfObjStation>
`;

function boardXML(status: string): string {
  return `
    <ArrayOfObjStationData>
      <objStationData>
        <Traincode>A226 </Traincode><Traindate>21 Jul 2026</Traindate>
        <Origin>Dublin Heuston</Origin><Destination>Cork</Destination><Status>${status}</Status>
        <Scharrival>00:00</Scharrival><Schdepart>19:00</Schdepart>
      </objStationData>
    </ArrayOfObjStationData>
  `;
}

const movementsXML = `
  <ArrayOfObjTrainMovements>
    <objTrainMovements>
      <LocationFullName>Dublin Heuston</LocationFullName><LocationType>O</LocationType>
      <ScheduledArrival>00:00:00</ScheduledArrival><ScheduledDeparture>19:00:00</ScheduledDeparture>
      <ExpectedArrival>00:00:00</ExpectedArrival><ExpectedDeparture>19:00:00</ExpectedDeparture>
    </objTrainMovements>
    <objTrainMovements>
      <LocationFullName>Portlaoise</LocationFullName><LocationType>S</LocationType>
      <ScheduledArrival>19:46:00</ScheduledArrival><ScheduledDeparture>19:48:00</ScheduledDeparture>
      <ExpectedArrival>19:51:00</ExpectedArrival><ExpectedDeparture>19:53:00</ExpectedDeparture>
    </objTrainMovements>
    <objTrainMovements>
      <LocationFullName>Cork</LocationFullName><LocationType>D</LocationType>
      <ScheduledArrival>21:48:00</ScheduledArrival><ScheduledDeparture>00:00:00</ScheduledDeparture>
      <ExpectedArrival>21:55:00</ExpectedArrival><ExpectedDeparture>00:00:00</ExpectedDeparture>
    </objTrainMovements>
  </ArrayOfObjTrainMovements>
`;

function runsXML(status: string): string {
  return `
  <ArrayOfObjHaconPositions>
    <objHaconPositions>
      <TrainLatitude>53.2451</TrainLatitude><TrainLongitude>-6.6642</TrainLongitude>
      <TrainCode>A226 </TrainCode><TrainStatus>${status}</TrainStatus><TrainDate>21 Jul 2026</TrainDate>
      <TrainOrigin>HSTON</TrainOrigin><TrainOriginTime>21/07/2026 19:00:00</TrainOriginTime>
      <TrainDestination>CORK</TrainDestination><TrainDestinationTime>21/07/2026 21:48:00</TrainDestinationTime>
    </objHaconPositions>
  </ArrayOfObjHaconPositions>
  `;
}

function fixtureFetcher(status = "En Route"): typeof fetch {
  return async (input) => {
    const url = new URL(String(input));
    if (url.pathname.endsWith("/getAllStationsXML")) return new Response(stationsXML);
    if (url.pathname.endsWith("/getTrainMovementsXML")) return new Response(movementsXML);
    if (url.pathname.endsWith("/getHaconTrainsXML")) return new Response(runsXML(status));
    if (url.pathname.endsWith("/getStationDataByCodeXML_WithNumMins")) return new Response(boardXML(status));
    return new Response("not found", { status: 404 });
  };
}

describe("IrishRailRealtimeOverlay", () => {
  it("maps official expected times into delay notification events", async () => {
    const previous = trip();
    const overlay = new IrishRailRealtimeOverlay(
      "https://irishrail.test/realtime.asmx",
      fixtureFetcher(),
      () => new Date("2026-07-21T17:55:00.000Z"),
    );

    const current = await new TripSnapshotEnricher([overlay], [overlay]).enrich(previous);
    const events = diffSnapshots(previous, current, defaultPushPreferences);

    expect(current.stops[1]).toMatchObject({
      expectedArrival: "2026-07-21T18:51:00.000Z",
      expectedDeparture: "2026-07-21T18:53:00.000Z",
      cancelled: false,
    });
    expect(current.stops[2]).toMatchObject({ expectedArrival: "2026-07-21T20:55:00.000Z" });
    expect(current.positions ?? []).toEqual([]);
    expect(events).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: "delay-threshold", stopId: previous.stops[1]!.stationId, newValue: "5" }),
    ]));
  });

  it("withholds undated coordinates instead of treating the request time as fresh GPS", async () => {
    let requests = 0;
    const overlay = new IrishRailRealtimeOverlay(
      "https://irishrail.test/realtime.asmx",
      async () => { requests += 1; return new Response(runsXML("En Route")); },
      () => new Date("2026-07-21T18:10:00.000Z"),
    );

    expect(await overlay.positionUpdates(trip())).toEqual([]);
    expect(requests).toBe(0);
  });

  it("maps a whole-trip cancellation without inventing a platform", async () => {
    const previous = trip();
    const overlay = new IrishRailRealtimeOverlay(
      "https://irishrail.test/realtime.asmx",
      fixtureFetcher("Cancelled"),
      () => new Date("2026-07-21T17:55:00.000Z"),
    );

    const current = await new TripSnapshotEnricher([overlay]).enrich(previous);
    const events = diffSnapshots(previous, current, defaultPushPreferences);

    expect(current.stops.every((stop) => stop.cancelled)).toBe(true);
    expect(current.stops.every((stop) => stop.expectedPlatform === null)).toBe(true);
    expect(events).toEqual([expect.objectContaining({ kind: "cancellation", stopId: null })]);
  });
});

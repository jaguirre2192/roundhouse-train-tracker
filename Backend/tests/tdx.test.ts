import { describe, expect, it } from "vitest";
import { RailProviderNotFoundError } from "../src/providers/provider.js";
import { TdxProvider } from "../src/providers/tdx.js";
import { tdxStops } from "../src/providers/tdx-values.js";

const today = "2026-11-18";
const now = "2026-11-18T09:05:00+08:00";
const reported = "2026-11-18T09:04:00+08:00";
const utcReport = "2026-11-18T01:04:00.000Z";
const name = (En: string, Zh_tw: string) => ({ En, Zh_tw });
const taipei = { StationID: "1000", StationName: name("Taipei", "臺北"), StationPosition: { PositionLat: 25.0478, PositionLon: 121.517 } };
const banqiao = { StationID: "1020", StationName: name("Banqiao", "板橋"), StationPosition: { PositionLat: 25.014, PositionLon: 121.463 } };
const taichung = { StationID: "3300", StationName: name("Taichung", "臺中"), StationPosition: { PositionLat: 24.136, PositionLon: 120.684 } };
const zuoying = { StationID: "1070", StationName: name("Zuoying", "左營"), StationPosition: { PositionLat: 22.687, PositionLon: 120.309 } };
const traInfo = { TrainNo: "117", TrainTypeCode: "3", TrainTypeName: name("Tze-Chiang Limited Express", "自強"), EndingStationName: taichung.StationName };
const stopTimes = [
  { ...taipei, StopSequence: 1, DepartureTime: "09:00:00", SuspendedFlag: 0 },
  { ...banqiao, StopSequence: 2, ArrivalTime: "09:06:00", DepartureTime: "09:08:00", SuspendedFlag: 0 },
  { ...taichung, StopSequence: 3, ArrivalTime: "11:10:00", SuspendedFlag: 0 },
];
const trainReport = { TrainNo: "117", StationID: "1000", TrainStationStatus: 2, DelayTime: 4, UpdateTime: reported };
const stationReport = { TrainNo: "117", StationID: "1020", ScheduleArrivalTime: "09:06:00", ScheduleDepartureTime: "09:08:00", DelayTime: 4, Platform: "2A", RunningStatus: 1, UpdateTime: reported };
const stationPath = "/v3/Rail/TRA/StationLiveBoard";
const trainPath = "/v3/Rail/TRA/TrainLiveBoard/TrainNo/117";
const traTodayPath = "/v3/Rail/TRA/DailyTrainTimetable/Today/TrainNo/117";
const traBoardPath = "/v3/Rail/TRA/DailyStationTimetable/Today/Station/1020";
const tdxRoot = "/api/basic";
const traTrip = { id: "tw:tdx:TRA:117", source: "tdx", nativeId: "TRA:117", serviceDate: today } as const;
const boardRef = { stationId: "tw:tdx:TRA:1020", source: "tdx", nativeId: "TRA:1020", at: now, direction: "departures" } as const;
type Payload = (url: URL) => unknown;

function fixture(overrides: Record<string, Payload> = {}, clock = now) {
  const urls: URL[] = [];
  const group = { StationID: "1020", StationName: banqiao.StationName, Direction: 0, TimeTables: [
    { ...traInfo, DestinationStationName: taichung.StationName, ArrivalTime: "09:06:00", DepartureTime: "09:08:00" },
    { ...traInfo, TrainNo: "2201", TrainTypeCode: "6", DepartureTime: "09:15", TrainTypeName: name("EMU", "電聯車") },
  ] };
  const data: Record<string, Payload> = {
    "/v3/Rail/TRA/Station": () => ({ Stations: [taipei, banqiao, taichung] }),
    "/v2/Rail/THSR/Station": () => [taipei, zuoying],
    [traTodayPath]: () => ({ TrainDate: today, TrainTimetables: [{ TrainInfo: traInfo, StopTimes: stopTimes }] }),
    [traBoardPath]: () => ({ TrainDate: today, StationTimetables: [group] }),
    [stationPath]: () => ({ StationLiveBoards: [stationReport] }),
    [stationPath + "/Station/1020"]: () => ({ StationLiveBoards: [stationReport] }),
    [trainPath]: () => ({ TrainLiveBoards: [trainReport] }),
    ...overrides,
  };
  const provider = new TdxProvider("test-client", "test-secret", "https://tdx.test/api/basic", "https://tdx.test/token", async (input, init) => {
    const url = new URL(String(input));
    urls.push(url);
    if (url.pathname === "/token") {
      expect(String(init?.body)).toContain("grant_type=client_credentials");
      return Response.json({ access_token: "test-token", expires_in: 3600 });
    }
    expect(new Headers(init?.headers).get("authorization")).toBe("Bearer test-token");
    expect(url.pathname.startsWith(tdxRoot + "/")).toBe(true);
    const response = data[url.pathname.slice(tdxRoot.length)]?.(url);
    if (response === undefined) throw new Error("Unexpected test request " + url.pathname);
    return response instanceof Response ? response : Response.json(response);
  }, () => new Date(clock));
  return { provider, urls };
}

describe("TDX rail schedules and observations", () => {
  it("preserves the Basic API path, handles v3 wrapped TRA and v2 THSR, and shares the access token", async () => {
    const { provider, urls } = fixture();
    const rows = await provider.searchStations("Taipei");
    expect(rows.map(row => row.nativeId)).toEqual(["THSR:1000", "TRA:1000"]);
    expect(rows[1]).toMatchObject({ name: "Taipei", latitude: 25.0478, longitude: 121.517 });
    expect(urls.map(url => url.pathname).sort()).toEqual(["/api/basic/v2/Rail/THSR/Station", "/api/basic/v3/Rail/TRA/Station", "/token"]);
    expect(urls.every(url => !url.href.includes("test-secret") && !url.href.includes("test-token"))).toBe(true);
    await provider.searchStations("臺北");
    expect(urls).toHaveLength(3);
  });

  it("keeps the available railway searchable and retries the unavailable station directory", async () => {
    let tries = 0;
    const { provider } = fixture({ "/v3/Rail/TRA/Station": () => ++tries === 1 ? new Response(null, { status: 503 }) : { Stations: [taipei] } });
    expect((await provider.searchStations("Taipei")).map(s => s.nativeId)).toEqual(["THSR:1000"]);
    expect(await provider.searchStations("Taipei")).toHaveLength(2);
  });

  it("binds a local station delay and named platform to the right train, stop and report time", async () => {
    const { provider, urls } = fixture();
    const board = await provider.fetchBoard(boardRef);
    expect(board).toHaveLength(1);
    expect(board[0]).toMatchObject({ product: "Tze-Chiang Limited Express 117", headsign: "Taichung",
      trip: { nativeId: "TRA:117", serviceDate: today }, stop: {
        scheduledDeparture: "2026-11-18T01:08:00.000Z", expectedDeparture: "2026-11-18T01:12:00.000Z",
        expectedDepartureEvidence: { observedAt: utcReport }, expectedPlatform: "2A", platformObservedAt: utcReport,
      } });
    const trip = await provider.fetchTrip(traTrip);
    expect(trip.stops[0]).toMatchObject({ passed: true, passageObservedAt: utcReport, expectedDeparture: null });
    expect(trip.stops[1]).toMatchObject({ expectedArrival: "2026-11-18T01:10:00.000Z", expectedArrivalEvidence: { observedAt: utcReport },
      expectedPlatform: "2A", latitude: banqiao.StationPosition.PositionLat });
    expect(trip.stops[2]).toMatchObject({ passed: false, expectedArrival: null });
    expect(trip.tripLevelDelay).toMatchObject({ seconds: 240, feedPublishedAt: utcReport });
    expect(trip.positions).toBeUndefined();
    expect(urls.find(url => url.pathname === tdxRoot + stationPath)?.searchParams.get("$filter")).toBe("TrainNo eq '117'");
  });

  it("keeps a late service on the board after its scheduled time and honors the requested direction", async () => {
    const { provider } = fixture({ [stationPath + "/Station/1020"]: () => ({ StationLiveBoards: [{ ...stationReport, DelayTime: 22 }] }) });
    const at = "2026-11-18T09:31:00+08:00";
    expect(await provider.fetchBoard({ ...boardRef, direction: "arrivals", at })).toHaveLength(1);
    expect((await provider.fetchBoard({ ...boardRef, at }))[0]?.stop.expectedDeparture).toBe("2026-11-18T01:30:00.000Z");
  });

  it("preserves an observed zero delay, suppresses an undecided platform and keeps passage distinct from arrival", async () => {
    const { provider } = fixture({
      [stationPath]: () => ({ StationLiveBoards: [{ ...stationReport, DelayTime: 0, RunningStatus: 0, Platform: "00" }] }),
      [trainPath]: () => ({ TrainLiveBoards: [{ ...trainReport, DelayTime: 0, TrainStationStatus: 1 }] }),
    });
    const trip = await provider.fetchTrip(traTrip);
    expect(trip.stops[0]).toMatchObject({ passed: false, arrivalObservedAt: utcReport });
    expect(trip.stops[1]?.expectedArrival).toBe(trip.stops[1]?.scheduledArrival);
    expect(trip.stops[1]?.expectedPlatform).toBeNull();
    expect(trip.tripLevelDelay?.seconds).toBe(0);
  });

  it("shows only the published cancelled stop and never sets a forecast for that call", async () => {
    const { provider } = fixture({ [stationPath]: () => ({ StationLiveBoards: [{ ...stationReport, RunningStatus: 2 }] }) });
    const trip = await provider.fetchTrip(traTrip);
    expect(trip.stops.map(s => s.cancelled)).toEqual([false, true, false]);
    expect(trip.stops[1]?.cancellationObservedAt).toBe(utcReport);
    expect(trip.stops[1]?.expectedArrival).toBeNull();
  });

  it.each([
    ["empty", { StationLiveBoards: [] }, { TrainLiveBoards: [] }],
    ["missing observation", { StationLiveBoards: [{ ...stationReport, UpdateTime: undefined }], UpdateTime: reported },
      { TrainLiveBoards: [{ ...trainReport, UpdateTime: undefined }], SrcUpdateTime: reported }],
    ["stale", { StationLiveBoards: [{ ...stationReport, UpdateTime: "2026-11-18T08:15:00+08:00" }] },
      { TrainLiveBoards: [{ ...trainReport, UpdateTime: "2026-11-18T08:15:00+08:00" }] }],
    ["future", { StationLiveBoards: [{ ...stationReport, UpdateTime: "2026-11-18T12:05:00+08:00" }] },
      { TrainLiveBoards: [{ ...trainReport, UpdateTime: "2026-11-18T12:05:00+08:00" }] }],
    ["another run", { StationLiveBoards: [{ ...stationReport, TrainNo: "118" }] }, { TrainLiveBoards: [{ ...trainReport, TrainNo: "118" }] }],
    ["duplicated", { StationLiveBoards: [stationReport, stationReport] }, { TrainLiveBoards: [trainReport, trainReport] }],
    ["quota or outage", new Response(null, { status: 429 }), new Response(null, { status: 503 })],
  ])("keeps the trip usable with %s live data", async (_, board, movement) => {
    const { provider } = fixture({ [stationPath]: () => board, [trainPath]: () => movement });
    const trip = await provider.fetchTrip(traTrip);
    expect(trip.stops).toHaveLength(3);
    expect(trip.stops.every(s => !s.passed && !s.passageObservedAt && !s.expectedArrival && !s.expectedDeparture && !s.expectedPlatform)).toBe(true);
    expect(trip.tripLevelDelay).toBeUndefined();
  });

  it("keeps reports at a passing, unscheduled station off the map and off booked stops", async () => {
    const { provider } = fixture({ [trainPath]: () => ({ TrainLiveBoards: [{ ...trainReport, StationID: "1010" }] }) });
    const trip = await provider.fetchTrip(traTrip);
    expect(trip.tripLevelDelay?.seconds).toBe(240);
    expect(trip.stops.every(s => !s.passed && !s.passageObservedAt)).toBe(true);
    expect(trip.positions).toBeUndefined();
  });

  it("retains schedules when individual forecasts lack a delay or their published clocks differ", async () => {
    const { provider } = fixture({ [stationPath]: () => ({ StationLiveBoards: [
      { ...stationReport, DelayTime: undefined, Platform: "00" },
      { ...stationReport, StationID: "3300", ScheduleArrivalTime: "11:30:00", ScheduleDepartureTime: null },
    ] }) });
    const trip = await provider.fetchTrip(traTrip);
    expect(trip.stops.every(s => !s.expectedArrival && !s.expectedDeparture)).toBe(true);
    expect(trip.stops[2]?.expectedPlatform).toBeNull();
  });

  it("uses a dated filtered TRA timetable and ignores a different date's response", async () => {
    const next = "2026-11-19", lookup = "/v3/Rail/TRA/DailyTrainTimetable/TrainDate/" + next;
    const { provider, urls } = fixture({ [lookup]: url => {
      expect(url.searchParams.get("$filter")).toBe("TrainInfo/TrainNo eq '117'");
      return { TrainDate: next, TrainTimetables: [{ TrainInfo: { ...traInfo, TrainNo: "118" }, StopTimes: [] }, { TrainInfo: traInfo, StopTimes: stopTimes }] };
    } });
    expect((await provider.fetchTrip({ ...traTrip, serviceDate: next })).stops).toHaveLength(3);
    expect(urls.some(url => url.pathname.includes("LiveBoard"))).toBe(false);
    const mismatch = fixture({ [lookup]: () => ({ TrainDate: today, TrainTimetables: [{ TrainInfo: traInfo, StopTimes: stopTimes }] }) });
    await expect(mismatch.provider.fetchTrip({ ...traTrip, serviceDate: next })).rejects.toBeInstanceOf(RailProviderNotFoundError);
  });

  it("keeps THSR boards and actual dated runs schedule-only, including leading-zero train numbers", async () => {
    const dept = "09:20:00", trainNo = "0803";
    const info = { TrainNo: trainNo, EndingStationName: zuoying.StationName };
    const { provider, urls } = fixture({
      ["/v2/Rail/THSR/DailyTimetable/Station/1000/" + today]: () => [{ TrainDate: today, ...taipei, ...info, DepartureTime: dept }],
      ["/v2/Rail/THSR/DailyTimetable/TrainNo/0803/TrainDate/" + today]: () => [{ TrainDate: today, DailyTrainInfo: info, StopTimes: [
        { ...taipei, StopSequence: 1, DepartureTime: dept }, { ...zuoying, StopSequence: 2, ArrivalTime: "11:30:00" },
      ] }],
    });
    const [board] = await provider.fetchBoard({ ...boardRef, nativeId: "THSR:1000" });
    expect(board!.trip.nativeId).toBe("THSR:0803");
    const trip = await provider.fetchTrip(board!.trip);
    expect(trip.stops.map(s => s.stationName)).toEqual(["Taipei", "Zuoying"]);
    expect(trip.stops.every(s => s.expectedArrival === null && s.expectedDeparture === null && !s.passed)).toBe(true);
    expect(trip.tripLevelDelay).toBeUndefined();
    expect(urls.some(url => url.pathname.includes("LiveBoard"))).toBe(false);
  });

  it("keeps a cancelled timetable available and preserves scoped stop suspensions", async () => {
    const suspended = (flag: number) => fixture({ [traTodayPath]: () => ({ TrainDate: today, TrainTimetables: [
      { TrainInfo: { ...traInfo, SuspendedFlag: flag }, StopTimes: stopTimes.map((stop, index) => ({ ...stop, SuspendedFlag: index === 1 ? 1 : 0 })) },
    ] }) });
    const full = suspended(1);
    const trip = await full.provider.fetchTrip(traTrip);
    expect(trip.stops.every(stop => stop.cancelled && !stop.cancellationObservedAt)).toBe(true);
    expect(full.urls.some(url => url.pathname.includes("LiveBoard"))).toBe(false);
    const partial = await suspended(2).provider.fetchTrip(traTrip);
    expect(partial.stops.map(stop => stop.cancelled)).toEqual([false, true, false]);
  });

  it("avoids spending a station directory request on a trip with existing mirror coordinates", async () => {
    const { provider, urls } = fixture();
    const trip = await provider.fetchTrip(traTrip, { includeStationCoordinates: false });
    expect(trip.tripLevelDelay?.seconds).toBe(240);
    expect(trip.stops[0]?.latitude).toBeNull();
    expect(urls.some(url => url.pathname.endsWith("/Station"))).toBe(false);
  });

  it("coalesces concurrent requests for the same run and retains original publication times", async () => {
    const { provider, urls } = fixture();
    const [first, second] = await Promise.all([provider.fetchTrip(traTrip), provider.fetchTrip(traTrip)]);
    expect([...new Set(urls.map(url => url.href))]).toHaveLength(urls.length);
    expect(first.tripLevelDelay?.feedPublishedAt).toBe(utcReport);
    expect(second.stops[1]?.expectedDepartureEvidence?.observedAt).toBe(utcReport);
  });

  it("honors yesterday's service date when the train reaches the next day and rejects the same number outside its trip", async () => {
    const afterMidnight = "2026-11-19T00:05:00+08:00", overnightReport = "2026-11-19T00:04:00+08:00";
    const route = "/v3/Rail/TRA/DailyTrainTimetable/TrainDate/" + today;
    const overnight = [{ ...taipei, StopSequence: 1, DepartureTime: "23:45" },
      { ...banqiao, StopSequence: 2, ArrivalTime: "23:58", DepartureTime: "00:02" },
      { ...taichung, StopSequence: 3, ArrivalTime: "01:15" }];
    const load = (times: typeof overnight | typeof stopTimes) => fixture({
      [route]: () => ({ TrainDate: today, TrainTimetables: [{ TrainInfo: traInfo, StopTimes: times }] }),
      [stationPath]: () => ({ StationLiveBoards: [] }),
      [trainPath]: () => ({ TrainLiveBoards: [{ ...trainReport, StationID: "1020", DelayTime: 2, UpdateTime: overnightReport }] }),
    }, afterMidnight);
    expect((await load(overnight).provider.fetchTrip(traTrip)).stops[1]?.passageObservedAt).toBe("2026-11-18T16:04:00.000Z");
    expect((await load(stopTimes).provider.fetchTrip(traTrip)).tripLevelDelay).toBeUndefined();
  });

  it("rolls arrival and departure independently through a station dwell at midnight", () => {
    const stops = tdxStops("TRA", today, [
      { ...taipei, StopSequence: 1, DepartureTime: "23:45" },
      { ...banqiao, StopSequence: 2, ArrivalTime: "23:58:00", DepartureTime: "00:02:00" },
      { ...zuoying, StopSequence: 3 },
      { ...taichung, StopSequence: 4, ArrivalTime: "25:15:00" },
    ], []);
    expect(stops[1]).toMatchObject({ scheduledArrival: "2026-11-18T15:58:00.000Z", scheduledDeparture: "2026-11-18T16:02:00.000Z" });
    expect(stops[2]?.scheduledArrival).toBeNull();
    expect(stops[3]?.scheduledArrival).toBe("2026-11-18T17:15:00.000Z");
  });
});

// The official train and station responses for TRA 143 on 18 November 2026
// disagree in precision. The live board also supplied its observation time.
describe("TRA 143 at Banqiao", () => {
  const actualTrip = { ...traTrip, id: "tw:tdx:TRA:143", nativeId: "TRA:143" };
  const stationObservation = { TrainNo: "143", StationID: "1020", ScheduleArrivalTime: "18:07:30",
    ScheduleDepartureTime: "18:08:30", DelayTime: 0, Platform: "", RunningStatus: 0, UpdateTime: "2026-11-18T17:57:47+08:00" };
  function run(arrival = "18:07", departure = "18:08", reports = [stationObservation]) {
    const info = { ...traInfo, TrainNo: "143", TrainTypeCode: "11" };
    const call = { ...banqiao, StopSequence: 6, ArrivalTime: arrival, DepartureTime: departure };
    return fixture({
      "/v3/Rail/TRA/DailyTrainTimetable/Today/TrainNo/143": () => ({ TrainDate: today, TrainTimetables: [
        { TrainInfo: info, StopTimes: [
          { ...taipei, StopSequence: 5, ArrivalTime: "17:57", DepartureTime: "18:00" }, call,
        ] },
      ] }),
      [traBoardPath]: () => ({ TrainDate: today, StationTimetables: [{ ...banqiao, TimeTables: [
        { ...info, DestinationStationName: taichung.StationName, ArrivalTime: arrival, DepartureTime: departure },
      ] }] }),
      [stationPath]: () => ({ StationLiveBoards: reports }),
      [stationPath + "/Station/1020"]: () => ({ StationLiveBoards: reports }),
      "/v3/Rail/TRA/TrainLiveBoard/TrainNo/143": () => ({ TrainLiveBoards: [
        { TrainNo: "143", StationID: "1000", TrainStationStatus: 2, DelayTime: 0, UpdateTime: stationObservation.UpdateTime },
      ] }),
    }, "2026-11-18T17:59:00+08:00").provider;
  }

  it("binds minute and second clocks on the board and trip, preserving operator seconds for an on-time service", async () => {
    const provider = run();
    const result = await provider.fetchTrip(actualTrip);
    const [board] = await provider.fetchBoard({ ...boardRef, at: "2026-11-18T17:59:00+08:00" });
    const expected = { scheduledArrival: "2026-11-18T10:07:00.000Z", expectedArrival: "2026-11-18T10:07:30.000Z",
      expectedDeparture: "2026-11-18T10:08:30.000Z", expectedDepartureEvidence: { observedAt: "2026-11-18T09:57:47.000Z" } };
    expect(board?.stop).toMatchObject(expected);
    expect(result.stops[1]).toMatchObject(expected);
    expect(result.stops[0]).toMatchObject({ passed: true, passageObservedAt: "2026-11-18T09:57:47.000Z" });
    expect(result.stops[0]?.arrivalObservedAt).toBeUndefined();
  });

  it("adds delay to the more precise board clock, or keeps a more precise timetable clock", async () => {
    const delayed = [{ ...stationObservation, DelayTime: 2, RunningStatus: 1 }];
    const expected = (await run("18:07", "18:08", delayed).fetchTrip(actualTrip)).stops[1]!;
    expect(expected.expectedArrival).toBe("2026-11-18T10:09:30.000Z");
    const abbreviated = [{ ...stationObservation, ScheduleArrivalTime: "18:07", ScheduleDepartureTime: "18:08" }];
    const planned = (await run("18:07:15", "18:08:45", abbreviated).fetchTrip(actualTrip)).stops[1]!;
    expect(planned.expectedArrival).toBe("2026-11-18T10:07:15.000Z");
    expect(planned.expectedDeparture).toBe("2026-11-18T10:08:45.000Z");
  });

  it.each([
    ["a neighboring minute", "18:07", "18:08", [{ ...stationObservation, ScheduleArrivalTime: "18:06:59" }]],
    ["conflicting published seconds", "18:07:00", "18:08", [stationObservation]],
    ["another train", "18:07", "18:08", [{ ...stationObservation, TrainNo: "144" }]],
    ["two plausible records", "18:07", "18:08", [stationObservation, { ...stationObservation, ScheduleArrivalTime: "18:07:45" }]],
  ] as const)("rejects %s", async (_, arrival, departure, reports) => {
    const stop = (await run(arrival, departure, [...reports]).fetchTrip(actualTrip)).stops[1]!;
    expect(stop.expectedArrival).toBeNull();
    expect(stop.expectedDeparture).toBeNull();
    expect(stop.expectedDepartureEvidence).toBeUndefined();
  });
});

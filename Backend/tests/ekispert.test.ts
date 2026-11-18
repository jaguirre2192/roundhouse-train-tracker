import { describe, expect, it } from "vitest";
import { EkispertProvider } from "../src/providers/ekispert.js";
import { ekispertSearchQueries } from "../src/providers/ekispert-search-aliases.js";
import { RailProviderNotFoundError } from "../src/providers/provider.js";

const station = {
  ResultSet: {
    Point: {
      GeoPoint: { lati_d: "35.681236", longi_d: "139.767125" },
      Prefecture: { code: "13", Name: "東京都" },
      Station: { code: "22828", Name: "東京", Type: "train" },
    },
  },
};

const overview = {
  ResultSet: {
    TimeTable: [
      {
        code: "1001",
        trainCount: "80",
        Station: { Name: "東京" },
        Line: { Name: "ＪＲ東海道新幹線", Direction: "新大阪", Source: "東京" },
      },
      {
        code: "2001",
        trainCount: "100",
        Station: { Name: "東京" },
        Line: { Name: "東京メトロ丸ノ内線", Direction: "荻窪", Source: "池袋" },
      },
    ],
  },
};

const timetable = {
  ResultSet: {
    TimeTable: {
      code: "1001",
      Station: { Name: "東京" },
      Line: { Name: "ＪＲ東海道新幹線", Direction: "新大阪", Source: "東京" },
      HourTable: {
        Hour: "12",
        MinuteTable: {
          Minute: "10",
          Stop: {
            lineCode: "9001",
            platformNo: "18",
            nameCode: "1",
            destinationCode: "1",
            kindCode: "1",
            Number: "45",
          },
        },
      },
      LineName: { text: "のぞみ", code: "1" },
      LineDestination: { text: "新大阪", code: "1" },
      LineKind: { text: "新幹線", code: "1" },
    },
  },
};

const trip = {
  ResultSet: {
    Line: {
      code: "9001",
      Name: { text: "新幹線 のぞみ45号", type_part: "新幹線", line_part: "のぞみ" },
      Number: "45",
      Stop: [
        {
          Point: {
            Prefecture: { code: "13", Name: "東京都" },
            Station: { code: "22828", Name: "東京", Type: "train" },
          },
          DepartureState: { Datetime: { text: "12:10:00+09:00", operation: "today" } },
        },
        {
          Point: {
            Prefecture: { code: "27", Name: "大阪府" },
            Station: { code: "25853", Name: "新大阪", Type: "train" },
          },
          ArrivalState: { Datetime: { text: "14:39:00+09:00", operation: "today" } },
        },
      ],
    },
  },
};

describe("EkispertProvider", () => {
  it("maps common English Shinkansen station names to licensed Japanese search terms", () => {
    expect(ekispertSearchQueries("Shin-Osaka Station")).toEqual(["新大阪", "Shin-Osaka Station"]);
  });

  it("discovers JR stations and excludes metro directions from the mainline board", async () => {
    const requests: URL[] = [];
    const provider = new EkispertProvider(
      "test-key",
      "https://example.test",
      async (input) => {
        const url = new URL(String(input));
        requests.push(url);
        if (url.pathname.endsWith("/station") && !url.pathname.includes("timetable")) return Response.json(station);
        if (url.pathname.endsWith("/operationLine/timetable")) {
          return Response.json(url.searchParams.has("code") ? timetable : overview);
        }
        return Response.json(trip);
      },
      () => new Date("2026-07-21T03:00:00.000Z"),
    );

    const stations = await provider.searchStations("Tokyo Station");
    expect(stations[0]).toMatchObject({
      id: "jp:ekispert:22828",
      name: "東京",
      source: "ekispert",
      countryCode: "JP",
    });

    const board = await provider.fetchBoard({
      stationId: stations[0]!.id,
      source: "ekispert",
      nativeId: stations[0]!.nativeId,
      at: "2026-07-21T03:00:00.000Z",
      direction: "departures",
    });
    expect(board).toHaveLength(1);
    expect(board[0]).toMatchObject({
      trip: { id: "jp:ekispert:9001~22828~18", source: "ekispert" },
      product: "のぞみ 45",
      headsign: "新大阪",
      stop: {
        plannedPlatform: "18",
        expectedPlatform: null,
        platformSource: "Ekispert timetable",
      },
    });
    expect(requests.filter((url) => url.searchParams.has("code"))).toHaveLength(1);

    const snapshot = await provider.fetchTrip(board[0]!.trip);
    expect(snapshot).toMatchObject({
      source: "ekispert",
      product: "新幹線 のぞみ45号",
      headsign: "新大阪",
    });
    expect(snapshot.stops).toHaveLength(2);
    expect(snapshot.stops[0]).toMatchObject({
      stationName: "東京",
      plannedPlatform: "18",
      scheduledDeparture: "2026-07-21T03:10:00.000Z",
      expectedDeparture: null,
    });
  });

  it("throws the typed provider error when a requested trip is absent", async () => {
    const provider = new EkispertProvider(
      "test-key",
      "https://example.test",
      async () => Response.json({ ResultSet: {} }),
    );

    await expect(provider.fetchTrip({
      id: "jp:ekispert:9001~22828~18",
      source: "ekispert",
      nativeId: "9001~22828~18",
      serviceDate: "2026-07-21",
    })).rejects.toBeInstanceOf(RailProviderNotFoundError);
  });
});

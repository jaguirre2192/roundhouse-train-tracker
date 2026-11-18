import { strToU8, zipSync } from "fflate";
import { describe, expect, it } from "vitest";
import { loadRenfeStaticIndex } from "../src/providers/renfe-static-loader.js";

function timetable(): Uint8Array<ArrayBuffer> {
  const tables = {
    "agency.txt": 'agency_id,agency_name,agency_timezone\n1071,"Renfe, \"\"rail\"\"  ",Europe/Madrid\n',
    "trips.txt": "route_id,service_id,trip_id,trip_headsign\nroute,service,0314312026-11-12,\n",
    "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n0314312026-11-12,14:27:00,14:27:00,60000,1\n0314312026-11-12,19:04:00,19:04:00,04307,2\n",
    "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nservice,1,1,1,1,1,1,1,20261112,20261212\n",
    "calendar_dates.txt": "service_id,date,exception_type\n",
  };
  const padded = Object.fromEntries(Object.entries(tables).map(([name, text]) => [name,
    strToU8(text.split("\n").map((line) => line ? `${line}${" ".repeat(300)}\r` : "").join("\n")),
  ]));
  return Uint8Array.from(zipSync(padded));
}

function streamed(bytes: Uint8Array): Response {
  let offset = 0;
  return new Response(new ReadableStream<Uint8Array>({
    pull(controller) {
      if (offset >= bytes.length) { controller.close(); return; }
      controller.enqueue(bytes.slice(offset, offset + 7)); offset += 7;
    },
  }));
}

describe("Renfe static loader in Workers", () => {
  it("decodes padded ZIP/CSV streams with Web APIs and fflate", async () => {
    const index = await loadRenfeStaticIndex(async () => streamed(timetable()));
    expect(index.trips.get("0314312026-11-12")).toEqual({ routeId: "route", serviceId: "service" });
    expect(index.calls.get("0314312026-11-12")).toEqual([
      { stationId: "60000", sequence: 1, arrival: 52020, departure: 52020 },
      { stationId: "04307", sequence: 2, arrival: 68640, departure: 68640 },
    ]);
  });

  it("retains compressed and inflated bounds after removing padding", async () => {
    await expect(loadRenfeStaticIndex(async () => streamed(timetable()), { maxCompressedBytes: 100 }))
      .rejects.toThrow("Oversized");
    await expect(loadRenfeStaticIndex(async () => streamed(timetable()), { maxUncompressedBytes: 1000 }))
      .rejects.toThrow("Oversized");
  });
});

import { strToU8, zipSync } from "fflate";

export function regionalStaticTables(): Record<string, string> {
  return {
    "trips.txt": "route_id,service_id,trip_id,trip_short_name\n1,5,1001,1231\n2,5,1002,99\n1,6,1003,1233\n",
    "stops.txt": 'stop_id,stop_name,stop_lat,stop_lon,parent_station,platform_code\n20,"Malmö, C",55.6,13,,\n21,Platform 1,55.6,13,20,1\n22,Platform 2,55.6,13,20,2\n30,Lund,55.7,13.2,,\n31,Platform 3,55.7,13.2,30,3\n',
    "calendar_dates.txt": "service_id,date,exception_type\n5,20261113,1\n5,20261114,2\n6,20261114,2\n",
    "shapes.txt": "unused,".repeat(1000),
    "feed_info.txt": "feed_version\n2026-11-13\n",
    "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n5,0,0,0,0,0,0,0,20261101,20261130\n6,0,0,0,0,0,0,0,20261101,20261130\n",
    "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n1001,23:50:00,23:50:00,21,1\n1002,12:00:00,12:00:00,21,1\n1001,24:20:00,24:20:00,31,2\n",
    // Match the official archive's adverse entry order: routes arrive last.
    "routes.txt": "route_id,route_type\n1,100\n2,700\n",
  };
}

export function regionalStaticFixture(tables = regionalStaticTables()): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(zipSync(Object.fromEntries(Object.entries(tables).map(([name, csv]) => [name, strToU8(csv)]))));
}

export function fixtureStream(bytes: Uint8Array, chunkSize = 17): ReadableStream<Uint8Array> {
  let offset = 0;
  return new ReadableStream({ pull(controller) {
    if (offset >= bytes.length) { controller.close(); return; }
    controller.enqueue(bytes.slice(offset, offset + chunkSize)); offset += chunkSize;
  } });
}

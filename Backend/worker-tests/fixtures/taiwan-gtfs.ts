import { strToU8, zipSync } from "fflate";

export function taiwanArchive(overrides: Record<string, string> = {}): ReadableStream<Uint8Array> {
  const tables = {
    "agency.txt": "agency_id,agency_name,agency_url,agency_timezone\nTRA,Taiwan Railway,https://railway.gov.tw,Asia/Taipei\nTHSR,Taiwan High Speed Rail,https://thsrc.com.tw,Asia/Taipei\nAFR,Alishan,https://example.org,Asia/Taipei\n",
    "routes.txt": "route_id,agency_id,route_short_name,route_long_name,route_type\nTRA_101,TRA,101,Taipei to Hualien,2\nTHSR_0817,THSR,817,Taipei to Zuoying,2\nAFR_1,AFR,1,Forest railway,2\nBUS,BUS,1,Bus,3\n",
    "trips.txt": "route_id,service_id,trip_id\nTRA_101,day1,tra-day1\nTRA_101,day2,tra-day2\nTHSR_0817,weekly,thsr\nAFR_1,weekly,forest\nBUS,weekly,bus\n",
    "stops.txt": "stop_id,stop_name,stop_lat,stop_lon\nTRA_1000,臺北,25.0478,121.517\nTRA_7000,花蓮,23.993,121.601\nTHSR_1000,台北,25.0477,121.517\nTHSR_1070,左營,22.687,120.307\nAFR_A,Forest,23.5,120.8\n",
    "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\nweekly,1,1,1,1,1,1,1,20261101,20261231\n",
    "calendar_dates.txt": "service_id,date,exception_type\nday1,20261114,1\nday2,20261115,1\nweekly,20261115,2\n",
    // Deliberately interleave trips and reverse sequences: GTFS has no row-order guarantee.
    "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\ntra-day2,26:10:00,26:10:00,TRA_7000,2\ntra-day1,23:50:00,23:50:00,TRA_1000,1\nthsr,08:00:00,08:00:00,THSR_1000,1\ntra-day2,23:50:00,23:50:00,TRA_1000,1\nforest,08:00:00,08:00:00,AFR_A,1\ntra-day1,26:10:00,26:10:00,TRA_7000,2\nthsr,10:00:00,10:00:00,THSR_1070,2\n",
    "fare_products.txt": "This is not CSV or a timetable. It must never be parsed.\n",
    ...overrides,
  };
  const zip = zipSync(Object.fromEntries(Object.entries(tables).map(([name, value]) => [name, strToU8(value)])));
  return new ReadableStream({ start(controller) { for (let i = 0; i < zip.length; i += 137) controller.enqueue(zip.slice(i, i + 137)); controller.close(); } });
}

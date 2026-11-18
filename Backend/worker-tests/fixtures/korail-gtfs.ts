import { strToU8, zipSync } from "fflate";
export function korailArchive(): ReadableStream<Uint8Array> {
  const tables = {
    "agency.txt": "agency_id,agency_name,agency_url,agency_timezone,agency_lang\nkorail,코레일,https://www.korail.com/,Asia/Seoul,ko\n",
    "routes.txt": "route_id,agency_id,route_short_name,route_long_name,route_type,route_type_extended\nktx,korail,KTX,,2,101\n",
    "trips.txt": "trip_id,route_id,service_id,shape_id,trip_short_name,trip_headsign\n1,ktx,127,0,1,부산\n2,ktx,127,0,2,부산\n",
    "stops.txt": "stop_id,stop_name,stop_lat,stop_lon\nseoul,서울,37.5547,126.9707\nbusan,부산,35.1152,129.0414\n",
    "calendar.txt": "service_id,start_date,end_date,monday,tuesday,wednesday,thursday,friday,saturday,sunday\n127,20261101,20271101,1,1,1,1,1,1,1\n",
    "calendar_dates.txt": "service_id,date,exception_type\n",
    "stop_times.txt": "trip_id,stop_sequence,stop_id,arrival_time,departure_time,shape_dist_traveled\n1,0,seoul,23:50:00,23:50:00,0\n1,1,busan,26:10:00,26:10:00,400\n2,0,seoul,23:50:00,23:50:00,0\n2,1,busan,26:10:00,26:10:00,400\n",
    "translations.txt": "table_name,record_id,field_name,language,translation\nstops,seoul,stop_name,en,Seoul\nstops,busan,stop_name,en,Busan\n",
  };
  const zip = zipSync(Object.fromEntries(Object.entries(tables).map(([name,value]) => [name,strToU8(value)])));
  return new ReadableStream({ start(controller) { controller.enqueue(zip); controller.close(); } });
}

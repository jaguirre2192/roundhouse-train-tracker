#!/usr/bin/env bash
set -euo pipefail

user_agent='Roundhouse/1.8.3 (+https://gettraintracker.com/support)'
transitous='https://api.transitous.org'

health=$(curl -fsS -H "User-Agent: ${user_agent}" "${transitous}/api/v1/health")
jq -e '.rt == true' >/dev/null <<<"${health}"

berlin=$(curl -fsSG -H "User-Agent: ${user_agent}" \
  --data-urlencode 'text=Berlin Hauptbahnhof' \
  --data-urlencode 'type=STOP' \
  --data-urlencode 'mode=RAIL' \
  --data-urlencode 'language=en' \
  --data-urlencode 'numResults=5' \
  "${transitous}/api/v1/geocode")
paris=$(curl -fsSG -H "User-Agent: ${user_agent}" \
  --data-urlencode 'text=Paris Est' \
  --data-urlencode 'type=STOP' \
  --data-urlencode 'mode=RAIL' \
  --data-urlencode 'language=en' \
  --data-urlencode 'numResults=10' \
  "${transitous}/api/v1/geocode")

berlin_id=$(jq -er 'map(select(.type == "STOP"))[0].id' <<<"${berlin}")
paris_id=$(jq -er 'map(select(.type == "STOP" and (.modes // [] | index("HIGHSPEED_RAIL"))))[0].id' <<<"${paris}")

board=$(curl -fsSG -H "User-Agent: ${user_agent}" \
  --data-urlencode "stopId=${berlin_id}" \
  --data-urlencode 'mode=RAIL' \
  --data-urlencode 'n=5' \
  --data-urlencode 'language=en' \
  "${transitous}/api/v6/stoptimes")
jq -e '.stopTimes | length > 0' >/dev/null <<<"${board}"

tomorrow=$(date -u -v+1d '+%Y-%m-%dT08:00:00Z')
plan=$(curl -fsSG -H "User-Agent: ${user_agent}" \
  --data-urlencode "fromPlace=${berlin_id}" \
  --data-urlencode "toPlace=${paris_id}" \
  --data-urlencode "time=${tomorrow}" \
  --data-urlencode 'maxTransfers=4' \
  --data-urlencode 'transitModes=HIGHSPEED_RAIL,LONG_DISTANCE,NIGHT_RAIL,REGIONAL_RAIL,SUBURBAN' \
  --data-urlencode 'detailedLegs=false' \
  --data-urlencode 'language=en' \
  "${transitous}/api/v6/plan")
jq -e '.itineraries | length > 0' >/dev/null <<<"${plan}"

belgium=$(curl -LfsSG -H "User-Agent: ${user_agent}" \
  --data-urlencode 'station=Brussels-South' \
  --data-urlencode 'format=json' \
  --data-urlencode 'lang=en' \
  'https://api.irail.be/v1/liveboard')
jq -e '.departures.departure | length > 0' >/dev/null <<<"${belgium}"

spain=$(curl -fsS -H "User-Agent: ${user_agent}" 'https://gtfsrt.renfe.com/vehicle_positions.json')
jq -e '[.entity[] | .vehicle.vehicle.label? | select(contains("PLATF.("))] | length > 0' >/dev/null <<<"${spain}"

printf 'Transitous: realtime healthy; Berlin board and Berlin–Paris plan available\n'
printf 'Belgium: iRail liveboard available\n'
printf 'Spain: Renfe platform-bearing vehicle feed available\n'

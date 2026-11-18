#!/usr/bin/env bash
set -euo pipefail

provider_base_url="${TRAIN_TRACKER_US_PROVIDER_BASE_URL:-https://api.amtraker.com/v3}"
provider_user_agent="Roundhouse/1.8.3 (+https://gettraintracker.com/support)"

for required_command in curl jq; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Missing required command: $required_command" >&2
    exit 1
  fi
done

request() {
  curl \
    --compressed \
    --fail \
    --silent \
    --show-error \
    --connect-timeout 5 \
    --max-time 15 \
    --retry 1 \
    --user-agent "$provider_user_agent" \
    "$1"
}

health_json="$(request "$provider_base_url/stale")"
station_json="$(request "$provider_base_url/stations/NYP")"

jq -e '
  .stale == false and
  (.activeTrains | type == "number") and
  .activeTrains > 0 and
  (.avgLastUpdate | type == "number")
' >/dev/null <<<"$health_json"

jq -e '
  .NYP.code == "NYP" and
  (.NYP.lat | type == "number") and
  (.NYP.lon | type == "number")
' >/dev/null <<<"$station_json"

jq -r '
  "Amtraker healthy: \(.activeTrains) active trains; average upstream age \((.avgLastUpdate / 1000) | floor)s."
' <<<"$health_json"

jq -r '
  "Station check: \(.NYP.name) (\(.NYP.code)), \(.NYP.tz)."
' <<<"$station_json"

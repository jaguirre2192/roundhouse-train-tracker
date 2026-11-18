import {
  historicalPlatformForecast,
  type HistoricalPlatformForecast,
  type HistoricalPlatformObservation,
  type PlatformEventType,
  type PlatformForecastRequest,
} from "../domain/platform-forecast.js";
import {
  historicalObservationFromPayload,
  observationEventIds,
  platformEventType,
  platformForecastRequest,
  platformShadowForecastId,
} from "../domain/platform-forecast-event.js";
import type { CanonicalPlatformObservation, CanonicalPlatformObservationPayload } from "../domain/platform-observation.js";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import {
  positionPlatformForecast,
  productionPlatformForecastReleasePolicy,
  productionStationPlatformGeographies,
  type PlatformForecastReleasePolicy,
  type StationPlatformGeography,
} from "../domain/platform-positioning.js";

interface ObservationPayloadRow extends Record<string, SqlStorageValue> {
  payload: string;
}

export class SQLitePlatformForecastStore {
  constructor(
    private readonly sql: SqlStorage,
    private readonly geographies: StationPlatformGeography[] = productionStationPlatformGeographies,
    private readonly releasePolicy: PlatformForecastReleasePolicy = productionPlatformForecastReleasePolicy,
  ) {}

  forecastSnapshot(snapshot: TripSnapshot, generatedAt: string): TripSnapshot {
    const stops = [...snapshot.stops];
    for (const [index, stop] of snapshot.stops.entries()) {
      if (stop.plannedPlatform !== null || stop.expectedPlatform !== null) continue;
      const type = platformEventType(snapshot, stop);
      if (type === null) continue;
      const history = this.history(stop.stationId, type, generatedAt);
      const sourceNames = [...new Set(history.map((value) => value.sourceName))];
      let selected: { request: PlatformForecastRequest; forecast: HistoricalPlatformForecast } | null = null;
      for (const sourceName of sourceNames) {
        const request = platformForecastRequest(snapshot, stop, type, sourceName, generatedAt);
        if (request === null) continue;
        const result = historicalPlatformForecast(request, history);
        if (result.kind === "forecast"
          && (selected === null || result.evidenceCount > selected.forecast.evidenceCount)) {
          selected = { request, forecast: result };
        }
      }
      if (selected !== null) {
        this.insert(selected.request, selected.forecast, stop);
        const positioned = positionPlatformForecast({
          request: selected.request,
          historical: selected.forecast,
          geography: this.geographies.find((value) => value.stationId === stop.stationId) ?? null,
          policy: this.releasePolicy,
          now: generatedAt,
        });
        if (positioned.kind === "forecast") stops[index] = { ...stop, platformForecast: positioned };
      }
    }
    return { ...snapshot, stops };
  }

  finalize(observations: CanonicalPlatformObservation[], scoredAt: string): void {
    for (const observation of observations) {
      if (!observation.passed || observation.cancelled) continue;
      for (const identifier of observationEventIds(observation)) {
        this.sql.exec(
          `UPDATE platform_shadow_forecasts SET
             actual_platform = ?,
             scored_at = ?,
             exact_correct = CASE WHEN likely_platform = ? THEN 1 ELSE 0 END
           WHERE event_id = ? AND scored_at IS NULL`,
          observation.effectivePlatform,
          Date.parse(scoredAt),
          observation.effectivePlatform,
          identifier,
        );
      }
    }
  }

  private history(
    stationId: string,
    type: PlatformEventType,
    before: string,
  ): HistoricalPlatformObservation[] {
    const rows = this.sql.exec<ObservationPayloadRow>(
      `WITH ranked AS (
         SELECT payload, platform_observed_at, last_observed_at,
                ROW_NUMBER() OVER (
                  PARTITION BY trip_source, native_trip_id, service_date, station_id, stop_sequence
                  ORDER BY platform_observed_at DESC, last_observed_at DESC, fingerprint DESC
                ) AS event_rank
         FROM platform_observations
         WHERE station_id = ? AND passed = 1 AND cancelled = 0 AND platform_observed_at < ?
       )
       SELECT payload FROM ranked
       WHERE event_rank = 1
       ORDER BY platform_observed_at DESC, last_observed_at DESC
       LIMIT 500`,
      stationId,
      Date.parse(before),
    ).toArray();
    return rows.flatMap((row) => {
      const payload = JSON.parse(row.payload) as CanonicalPlatformObservationPayload;
      const observation = historicalObservationFromPayload(payload, type);
      return observation === null ? [] : [observation];
    });
  }

  private insert(
    request: PlatformForecastRequest,
    forecast: HistoricalPlatformForecast,
    stop: StopSnapshot,
  ): void {
    this.sql.exec(
      `INSERT INTO platform_shadow_forecasts (
         id, event_id, source_name, station_id, station_name, service_date,
         stop_sequence, event_type, scheduled_time, horizon, model_version,
         timetable_period, cohort, evidence_count, likely_platform, top_probability,
         candidates, generated_at, expires_at
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (id) DO NOTHING`,
      platformShadowForecastId(request, forecast),
      request.eventId,
      request.sourceName,
      request.stationId,
      stop.stationName,
      request.serviceDate,
      stop.sequence,
      request.eventType,
      Date.parse(request.scheduledTime),
      forecast.horizon,
      forecast.modelVersion,
      forecast.timetablePeriod,
      forecast.cohort,
      forecast.evidenceCount,
      forecast.likelyPlatform,
      forecast.candidates[0]?.probability ?? 0,
      JSON.stringify(forecast.candidates),
      Date.parse(forecast.generatedAt),
      Date.parse(forecast.expiresAt),
    );
  }
}

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
import type { DatabaseClient } from "./database.js";
import {
  positionPlatformForecast,
  productionPlatformForecastReleasePolicy,
  productionStationPlatformGeographies,
  type PlatformForecastReleasePolicy,
  type StationPlatformGeography,
} from "../domain/platform-positioning.js";

export class PostgresPlatformForecastStore {
  constructor(
    private readonly geographies: StationPlatformGeography[] = productionStationPlatformGeographies,
    private readonly releasePolicy: PlatformForecastReleasePolicy = productionPlatformForecastReleasePolicy,
  ) {}

  async forecastSnapshot(
    client: DatabaseClient,
    snapshot: TripSnapshot,
    generatedAt: string,
  ): Promise<TripSnapshot> {
    const stops = [...snapshot.stops];
    for (const [index, stop] of snapshot.stops.entries()) {
      if (stop.plannedPlatform !== null || stop.expectedPlatform !== null) continue;
      const type = platformEventType(snapshot, stop);
      if (type === null) continue;
      const history = await this.history(client, stop.stationId, type, generatedAt);
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
        await this.insert(client, selected.request, selected.forecast, stop);
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

  async finalize(
    client: DatabaseClient,
    observations: CanonicalPlatformObservation[],
    scoredAt: string,
  ): Promise<void> {
    for (const observation of observations) {
      if (!observation.passed || observation.cancelled) continue;
      for (const identifier of observationEventIds(observation)) {
        await client.query(
          `UPDATE platform_shadow_forecasts SET
             actual_platform = $1,
             scored_at = $2,
             exact_correct = (likely_platform = $1)
           WHERE event_id = $3 AND scored_at IS NULL`,
          [observation.effectivePlatform, scoredAt, identifier],
        );
      }
    }
  }

  private async history(
    client: DatabaseClient,
    stationId: string,
    type: PlatformEventType,
    before: string,
  ): Promise<HistoricalPlatformObservation[]> {
    const result = await client.query<{ payload: CanonicalPlatformObservationPayload }>(
      `WITH ranked AS (
         SELECT payload, platform_observed_at, last_observed_at,
                ROW_NUMBER() OVER (
                  PARTITION BY trip_source, native_trip_id, service_date, station_id, stop_sequence
                  ORDER BY platform_observed_at DESC, last_observed_at DESC, fingerprint DESC
                ) AS event_rank
         FROM platform_observations
         WHERE station_id = $1 AND passed = TRUE AND cancelled = FALSE AND platform_observed_at < $2
       )
       SELECT payload FROM ranked
       WHERE event_rank = 1
       ORDER BY platform_observed_at DESC, last_observed_at DESC
       LIMIT 500`,
      [stationId, before],
    );
    return result.rows.flatMap((row) => {
      const observation = historicalObservationFromPayload(row.payload, type);
      return observation === null ? [] : [observation];
    });
  }

  private async insert(
    client: DatabaseClient,
    request: PlatformForecastRequest,
    forecast: HistoricalPlatformForecast,
    stop: StopSnapshot,
  ): Promise<void> {
    await client.query(
      `INSERT INTO platform_shadow_forecasts (
         id, event_id, source_name, station_id, station_name, service_date,
         stop_sequence, event_type, scheduled_time, horizon, model_version,
         timetable_period, cohort, evidence_count, likely_platform, top_probability,
         candidates, generated_at, expires_at
       ) VALUES (
         $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
         $11, $12, $13, $14, $15, $16, $17, $18, $19
       ) ON CONFLICT (id) DO NOTHING`,
      [
        platformShadowForecastId(request, forecast),
        request.eventId,
        request.sourceName,
        request.stationId,
        stop.stationName,
        request.serviceDate,
        stop.sequence,
        request.eventType,
        request.scheduledTime,
        forecast.horizon,
        forecast.modelVersion,
        forecast.timetablePeriod,
        forecast.cohort,
        forecast.evidenceCount,
        forecast.likelyPlatform,
        forecast.candidates[0]?.probability ?? 0,
        JSON.stringify(forecast.candidates),
        forecast.generatedAt,
        forecast.expiresAt,
      ],
    );
  }
}

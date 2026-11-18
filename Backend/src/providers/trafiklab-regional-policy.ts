/** Silver approved 2026-11-16 for the separate GTFS Regional realtime key.
 * Official allowance: 250/minute and 2,000,000/month. Keep headroom for other
 * uses of the key; the paired 30-second lanes need only 178,560 calls/31 days.
 * This does not upgrade static GTFS or the separate national Sweden RT key. */
export const trafiklabRegionalSilverPolicy = {
  rollingRequestCap: 1_800_000,
  sharedMinimumIntervalMilliseconds: 0,
  laneMinimumIntervalMilliseconds: 30_000,
  minimumFetchIntervalMilliseconds: 30_000,
} as const;

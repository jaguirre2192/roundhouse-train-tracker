import type { TripSnapshot } from "../domain/snapshot.js";

export function isStorageWriteQuotaExceeded(error: unknown): boolean {
  return error instanceof Error
    && error.message.includes("Exceeded allowed rows written in Durable Objects free tier");
}

/** Platform research is optional; the provider's fresh result remains useful. */
export function withOptionalPlatformPersistence(
  snapshot: TripSnapshot,
  persist: () => TripSnapshot,
): TripSnapshot {
  try {
    return persist();
  } catch (error) {
    if (!isStorageWriteQuotaExceeded(error)) throw error;
    console.info("platform_persistence", { outcome: "storage_write_quota_exceeded" });
    return snapshot;
  }
}

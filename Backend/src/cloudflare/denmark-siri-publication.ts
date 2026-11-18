import { DenmarkSiriIngestError, DenmarkSiriStore, type DenmarkSiriStorage } from "./denmark-siri-store.js";

export async function ingestDenmarkSiriPublication(storage: DenmarkSiriStorage, xml: string) {
  try {
    const result = await new DenmarkSiriStore(storage).ingest(xml);
    // Returning this ACK follows the durable transaction, never a queued write.
    return { accepted: true as const, source: "denmark-siri" as const, ...result };
  } catch (error) {
    if (error instanceof DenmarkSiriIngestError) {
      return { accepted: false as const, source: "denmark-siri" as const, outcome: "invalid" as const };
    }
    throw error;
  }
}

export async function ingestDenmarkSiriBatchPublication(storage: DenmarkSiriStorage, xml: readonly string[]) {
  try {
    const result = await new DenmarkSiriStore(storage).ingestBatch(xml);
    return { accepted: true as const, source: "denmark-siri" as const, ...result };
  } catch (error) {
    if (error instanceof DenmarkSiriIngestError) {
      return { accepted: false as const, source: "denmark-siri" as const, outcome: "invalid" as const };
    }
    throw error;
  }
}

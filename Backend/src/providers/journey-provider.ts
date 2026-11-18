import type { JourneyOptionSnapshot, RailPlaceSnapshot } from "../domain/journey.js";

export interface ProviderJourneySearchRequest {
  originId: string;
  destinationId: string;
  time: string;
  arriveBy: boolean;
  maxTransfers: number;
  /** Raw upstream cursor obtained only after the service validates its signed wrapper. */
  providerCursor: string | null;
}

export interface ProviderJourneySearchResult {
  options: JourneyOptionSnapshot[];
  previousProviderCursor: string | null;
  nextProviderCursor: string | null;
  attributions: string[];
}

export class JourneyProviderUnavailableError extends Error {
  constructor(message = "Journey provider unavailable") {
    super(message);
    this.name = "JourneyProviderUnavailableError";
  }
}

export interface JourneySearchProvider {
  metricProviderForPlaces?(query: string): "transitous" | "srbijavoz" | "multiple";
  metricProviderForSearch?(input: Pick<ProviderJourneySearchRequest, "originId" | "destinationId">): "transitous" | "srbijavoz";
  searchPlaces(query: string, limit: number): Promise<RailPlaceSnapshot[]>;
  searchJourneys(input: ProviderJourneySearchRequest): Promise<ProviderJourneySearchResult>;
}

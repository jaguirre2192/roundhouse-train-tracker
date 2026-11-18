import { TransitousJourneyProvider } from "./transitous-journeys.js";
import { TransitousProvider } from "./transitous.js";

function motisEndpoint(baseURL: string): URL {
  const url = new URL(baseURL);
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password
    || url.pathname !== "/" || url.search || url.hash) {
    throw new Error("MOTIS_BASE_URL must be an HTTP(S) origin with no path, credentials, query or fragment");
  }
  return url;
}

/** Planning and saved-train refresh must use the same MOTIS instance and dataset identifiers. */
export function configuredMotis(baseURL?: string) {
  const origin = baseURL?.trim() ? motisEndpoint(baseURL).origin : undefined;
  return {
    discovery: new TransitousProvider(origin),
    journeys: new TransitousJourneyProvider(origin),
  };
}

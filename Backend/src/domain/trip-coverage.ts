/** Consumer capability facts are separate from a particular realtime observation. */
export const coverageFeatures = ["delays", "cancellations", "platforms", "position"] as const;
export type CoverageFeature = typeof coverageFeatures[number];
export type CoverageSupport = "connected" | "notProvided" | "unknown";
export type CoverageAvailability = "observed" | "notObserved" | "unavailable";

export interface CoverageFeatureAssessment {
  support: CoverageSupport;
  availability: CoverageAvailability;
  observedAt: string | null;
}

export interface TripCoverage {
  schemaVersion: 1;
  assessedAt: string;
  reviewedAt: string;
  scopeName: string;
  countryCodes: string[];
  sourceIds: string[];
  features: Record<CoverageFeature, CoverageFeatureAssessment>;
  limitationCodes: string[];
  detailsURL: string;
}

/** Nonsecret configuration only; never serialize provider credentials. */
export interface CoverageConfiguration {
  enabledSources: ReadonlySet<string>;
}

export interface TripCoveragePolicy {
  scopeName: string;
  sourceIds: string[];
  support: Record<CoverageFeature, CoverageSupport>;
  limitationCodes: string[];
}

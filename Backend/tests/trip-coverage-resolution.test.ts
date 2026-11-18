import { describe, expect, it } from "vitest";
import { createJourneyTrackingToken } from "../src/domain/journey-tokens.js";
import { RailProviderNotFoundError } from "../src/providers/provider.js";
import { canonicalReference, option, reference, serviceFixture, tokenSecret, trip } from "./helpers/journey-search-service-fixtures.js";

describe("coverage travels inside normal journey resolution", () => {
  it("keeps mixed-leg snapshots and identity intact without an additional provider call", async () => {
    const fixture = serviceFixture();
    const known = reference("amtraker", "55");
    const uncertain = reference("transitous", "20260724_08:00_dk-rejseplanen_1");
    const token = createJourneyTrackingToken(option("mixed-coverage", [
      { segmentId: "known", reference: known }, { segmentId: "uncertain", reference: uncertain },
    ]), tokenSecret, new Date(fixture.nowRef.value)).token;
    const result = await fixture.service.resolvePlan([token], "coverage-test");
    const segments = result.directions[0]!.segments;
    expect(segments[0]!.trip).toEqual(trip(known));
    expect(segments[1]!.trip).toEqual(trip(uncertain));
    expect(segments[0]!.coverage.features.delays.support).toBe("connected");
    expect(segments[1]!.coverage.features.delays.support).toBe("unknown");
    expect(segments.every((segment) => segment.failure === null && segment.trip !== null)).toBe(true);
    expect(fixture.amtraker.references).toEqual([known]);
    expect(fixture.transitous.references).toEqual([uncertain]);
    expect(JSON.stringify(result)).not.toContain("enabledSources");
  });

  it("keeps provider outages retryable and separate from permanent source coverage", async () => {
    const fixture = serviceFixture();
    const missing = reference("transitous", "missing");
    const failed = reference("amtraker", "55");
    fixture.transitous.behaviors.set(canonicalReference(missing), new RailProviderNotFoundError());
    fixture.amtraker.behaviors.set(canonicalReference(failed), new Error("private upstream diagnostic"));
    const token = createJourneyTrackingToken(option("unavailable-coverage", [
      { segmentId: "missing", reference: missing }, { segmentId: "retry", reference: failed },
    ]), tokenSecret, new Date(fixture.nowRef.value)).token;
    const result = await fixture.service.resolvePlan([token], "coverage-failure-test");
    const segments = result.directions[0]!.segments;
    expect(segments[0]!.failure?.code).toBe("not_found");
    expect(segments[0]!.coverage.features.position.availability).toBe("notObserved");
    expect(segments[1]!.failure?.code).toBe("provider_unavailable");
    expect(segments[1]!.coverage.features.position).toMatchObject({ support: "unknown", availability: "unavailable" });
    expect(JSON.stringify(result)).not.toContain("private upstream diagnostic");

    fixture.amtraker.behaviors.delete(canonicalReference(failed));
    const recovered = await fixture.service.resolvePlan([token], "coverage-failure-test");
    expect(recovered.directions[0]!.segments[1]!.failure).toBeNull();
    expect(recovered.directions[0]!.segments[1]!.trip?.nativeId).toBe(failed.nativeId);
    expect(recovered.directions[0]!.segments[1]!.coverage.features.position.availability).toBe("notObserved");
  });
});

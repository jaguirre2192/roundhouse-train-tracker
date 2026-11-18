import { describe, expect, it, vi } from "vitest";
import { MainlineJourneyProvider } from "../src/providers/mainline-journeys.js";
import { SrbijaVozProvider } from "../src/providers/srbijavoz-provider.js";
import { encodeRailPlaceId, decodeRailPlaceId } from "../src/providers/rail-place-id.js";
import { srbijaVozPlace, srbijaVozStations } from "../src/providers/srbijavoz-stations.js";
import { TransitousJourneyProvider } from "../src/providers/transitous-journeys.js";
import type { RailPlaceSnapshot } from "../src/domain/journey.js";
import type { ProviderJourneySearchRequest } from "../src/providers/journey-provider.js";

const station = (nativeId: string, countryCode = "RS", provider: "transitous" | "srbijavoz" = "transitous") =>
  encodeRailPlaceId({ provider, kind: "station", nativeId, countryCode, latitude: null, longitude: null });
const request = (originId: string, destinationId: string) => ({
  originId, destinationId, time: "2026-11-13T10:00:00Z", arriveBy: false, maxTransfers: 2, providerCursor: null,
});
const empty = { options: [], previousProviderCursor: null, nextProviderCursor: null, attributions: [] };

function setup() {
  const official = new SrbijaVozProvider();
  const aggregate = {
    searchPlaces: vi.fn(async (_query: string, _limit: number): Promise<RailPlaceSnapshot[]> => []),
    searchJourneys: vi.fn(async (_input: ProviderJourneySearchRequest) => empty),
  };
  const provider = new MainlineJourneyProvider(official, aggregate);
  return { official, aggregate, provider };
}

describe("current Serbian source selection", () => {
  it("uses official schedules for saved aggregate identities and never masks an outage with old trains", async () => {
    const { official, aggregate, provider } = setup();
    const search = vi.spyOn(official, "searchJourneys").mockRejectedValue(new Error("official unavailable"));
    const input = request(station("hu-mav_1:007216052"), station("rs-Srbijavoz_7216807"));
    expect(provider.metricProviderForSearch(input)).toBe("srbijavoz");
    expect(provider.metricProviderForPlaces("Petrovaradin")).toBe("multiple");
    await expect(provider.searchJourneys(input)).rejects.toThrow("official unavailable");
    expect(search).toHaveBeenCalledWith(input);
    expect(aggregate.searchJourneys).not.toHaveBeenCalled();
  });

  it("preserves an international route by translating only the explicit official station identity", async () => {
    const { aggregate, provider } = setup();
    const input = request(station("16052", "RS", "srbijavoz"), station("me-rail_bar", "ME"));
    await provider.searchJourneys(input);
    const forwarded = aggregate.searchJourneys.mock.calls[0]?.[0] as typeof input | undefined;
    expect(decodeRailPlaceId(forwarded!.originId).nativeId).toBe("rs-Srbijavoz_7200080");
    expect(forwarded!.destinationId).toBe(input.destinationId);
  });

  it("does not substitute Petrovaradin for the old Novi Sad station", async () => {
    const { official, aggregate, provider } = setup();
    const search = vi.spyOn(official, "searchJourneys");
    await provider.searchJourneys(request(station("16052", "RS", "srbijavoz"), station("hu-mav_1:007216808")));
    expect(search).not.toHaveBeenCalled();
    expect(aggregate.searchJourneys).toHaveBeenCalledOnce();
  });

  it("keeps other countries in short-query results while removing only the verified duplicate", async () => {
    const { aggregate, provider } = setup();
    const duplicate = { ...srbijaVozPlace(srbijaVozStations[0]), id: station("rs-Srbijavoz_7200080") };
    const berlin = { ...duplicate, id: station("de-berlin", "DE"), displayName: "Berlin Hbf", countryCode: "DE" };
    aggregate.searchPlaces.mockResolvedValue([duplicate, berlin]);
    const places = await provider.searchPlaces("Be", 20);
    expect(places.map((place) => place.displayName)).toEqual(["Beograd Centar-PROKOP", "Berlin Hbf"]);
  });

  it("rejects an untranslated foreign provider ID before calling Transitous", async () => {
    const fetcher = vi.fn();
    const provider = new TransitousJourneyProvider("https://provider.test", fetcher);
    await expect(provider.searchJourneys(request(station("99999", "RS", "srbijavoz"), station("de-berlin", "DE"))))
      .rejects.toThrow("not eligible");
    expect(fetcher).not.toHaveBeenCalled();
  });
});

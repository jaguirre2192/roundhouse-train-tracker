import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation } from "./platform-overlay.js";

function xmlValue(fragment: string, tag: string): string | null {
  const match = fragment.match(new RegExp(`<${tag}>([^<]*)</${tag}>`, "u"));
  return match?.[1]?.trim().replaceAll("&amp;", "&").replaceAll("&apos;", "'") || null;
}

function xmlTime(fragment: string, tag: string): string | null {
  const value = xmlValue(fragment, tag);
  if (value === null) return null;
  const milliseconds = Date.parse(value);
  return Number.isFinite(milliseconds) ? new Date(milliseconds).toISOString() : null;
}

export function sncfStationCodes(id: string): string[] {
  // SNCF's new LMO/LMU identifiers contain UUIDs whose numeric groups are not UICs.
  if (/::LM[OU]:[\da-f]{8}-/iu.test(id)) return [];
  return [...id.matchAll(/(?:^|[^\da-f])(\d{7,8})(?=$|[^\da-f])/giu)]
    .flatMap((match) => match[1] === undefined ? [] : [match[1]]);
}

function stationName(value: string): string {
  const name = value.normalize("NFKD").replace(/\p{Diacritic}/gu, "")
    .toLowerCase().replace(/[^\p{Letter}\p{Number}]+/gu, " ").trim()
    .replace(/^gare (?:sncf )?(?:(?:de|d) )?/u, "").replace(/ gare$/u, "");
  // The ZOU station label describes this same railway station's entrance.
  if (name === "monaco pont sainte devote") return "monaco monte carlo";
  return name === "nice ville" ? "nice" : name;
}

function callTimeMatches(stop: StopSnapshot, call: string): boolean {
  return [[stop.scheduledDeparture, xmlTime(call, "AimedDepartureTime")],
    [stop.scheduledArrival, xmlTime(call, "AimedArrivalTime")]]
    .some(([scheduled, aimed]) => scheduled !== null && scheduled !== undefined && aimed !== null
      && aimed !== undefined && Math.abs(Date.parse(scheduled) - Date.parse(aimed)) <= 60_000);
}

function siriStop(snapshot: TripSnapshot, call: string): StopSnapshot | undefined {
  const codes = sncfStationCodes(xmlValue(call, "StopPointRef") ?? "");
  const codeMatches = snapshot.stops.filter((stop) => sncfStationCodes(stop.stationId).some((stationCode) =>
    codes.some((code) => stationCode.startsWith(code) || code.startsWith(stationCode))
  ));
  if (codeMatches.length === 1) return codeMatches[0];
  if (codeMatches.length > 1) return codeMatches.filter((stop) => callTimeMatches(stop, call)).length === 1
    ? codeMatches.find((stop) => callTimeMatches(stop, call)) : undefined;
  const name = xmlValue(call, "StopPointName");
  if (name === null) return undefined;
  // UUID-based federation IDs have no shared UIC. Require both an exact station
  // label and the scheduled call time; call order is never a station identity.
  const named = snapshot.stops.filter((stop) => sncfStationCodes(stop.stationId).length === 0
    && stationName(stop.stationName) === stationName(name) && callTimeMatches(stop, call));
  return named.length === 1 ? named[0] : undefined;
}

function siriJourney(xml: string, snapshot: TripSnapshot, numbers: string[]): string | null {
  const candidates: Array<{ value: string; matches: number }> = [];
  for (const number of numbers) {
    const marker = `<TrainNumberRef>${number}</TrainNumberRef>`;
    let cursor = 0;
    while (cursor < xml.length) {
      const numberAt = xml.indexOf(marker, cursor);
      if (numberAt < 0) break;
      cursor = numberAt + marker.length;
      const start = xml.lastIndexOf("<EstimatedVehicleJourney>", numberAt);
      const end = xml.indexOf("</EstimatedVehicleJourney>", cursor);
      if (start < 0 || end < 0) continue;
      const value = xml.slice(start, end + "</EstimatedVehicleJourney>".length);
      if (xmlValue(value, "DataFrameRef") !== snapshot.serviceDate) continue;
      const matches = [...value.matchAll(/<(EstimatedCall|RecordedCall)>([\s\S]*?)<\/\1>/gu)]
        .filter((call) => siriStop(snapshot, call[2] ?? "") !== undefined).length;
      if (matches > 0 && !candidates.some((candidate) => candidate.value === value)) candidates.push({ value, matches });
    }
  }
  candidates.sort((left, right) => right.matches - left.matches);
  if (candidates.length === 0 || (candidates.length > 1 && candidates[0]!.matches === candidates[1]!.matches)) return null;
  return candidates[0]!.value;
}

export function siriObservations(
  xml: string, snapshot: TripSnapshot, source: string, numbers: string[],
  matchedStation?: (stop: StopSnapshot, codes: string[]) => void,
): PlatformObservation[] {
  const journey = siriJourney(xml, snapshot, numbers);
  if (journey === null) return [];
  const observedAt = xmlTime(journey, "RecordedAtTime");
  // Never replace a missing provider timestamp with retrieval time for actual proof.
  if (observedAt === null) return [];
  const journeyCancelled = xmlValue(journey, "Cancellation")?.toLowerCase() === "true";
  return [...journey.matchAll(/<(EstimatedCall|RecordedCall)>([\s\S]*?)<\/\1>/gu)]
    .flatMap((match): PlatformObservation[] => {
      const call = match[2] ?? "";
      const stop = siriStop(snapshot, call);
      if (stop === undefined) return [];
      matchedStation?.(stop, sncfStationCodes(xmlValue(call, "StopPointRef") ?? ""));
      const expectedPlatform = xmlValue(call, "DeparturePlatformName") ?? xmlValue(call, "ArrivalPlatformName");
      const expectedArrival = xmlTime(call, "ExpectedArrivalTime") ?? undefined;
      const expectedDeparture = xmlTime(call, "ExpectedDepartureTime") ?? undefined;
      const cancelled = journeyCancelled || xmlValue(call, "Cancellation")?.toLowerCase() === "true";
      const actual = (tag: string) => {
        const time = match[1] === "RecordedCall" && !cancelled ? xmlTime(call, tag) : null;
        return time !== null && Date.parse(time) <= Date.parse(observedAt) + 120_000
          && Date.parse(time) <= Date.parse(snapshot.fetchedAt) + 120_000 ? time : undefined;
      };
      const arrivalObservedAt = actual("ActualArrivalTime");
      const departureObservedAt = actual("ActualDepartureTime");
      // An actual terminal arrival completes the call. At an intermediate stop,
      // arrival proves presence at the station, while departure proves passage.
      const passageObservedAt = departureObservedAt
        ?? (stop.scheduledDeparture === null ? arrivalObservedAt : undefined);
      if (expectedPlatform === null && expectedArrival === undefined && expectedDeparture === undefined
        && arrivalObservedAt === undefined && passageObservedAt === undefined && !cancelled) return [];
      return [{
        stopSequence: stop.sequence, stationId: stop.stationId, expectedPlatform,
        expectedArrival, expectedDeparture, cancelled,
        ...(arrivalObservedAt === undefined ? {} : { arrivalObservedAt }),
        ...(passageObservedAt === undefined ? {} : { passed: true, passageObservedAt }),
        observedAt, source,
      }];
    });
}

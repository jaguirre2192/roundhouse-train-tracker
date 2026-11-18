import { createHash } from "node:crypto";
import type { JourneyCallSnapshot, JourneyOptionSnapshot } from "../domain/journey.js";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import { srbijaVozTripReference } from "./srbijavoz-identity.js";
import { srbijaVozAttributions, srbijaVozPlace, srbijaVozStation } from "./srbijavoz-stations.js";
import { shiftSrbijaVozDate, srbijaVozClockMinutes, srbijaVozInstant, validSrbijaVozDate } from "./srbijavoz-time.js";
import { isSrbijaVozMainline, type SrbijaVozConnection } from "./srbijavoz-types.js";

export interface SrbijaVozMappedConnection {
  snapshot: TripSnapshot;
  option: JourneyOptionSnapshot;
}

function routeTimes(row: SrbijaVozConnection, serviceDate: string): Array<{ arrival: string; departure: string }> {
  const stops = row.etTrasaVoza;
  const fromIndex = stops.findIndex((stop) => stop.sifrA_STANICE === row.odsifra);
  const toIndex = stops.findIndex((stop) => stop.sifrA_STANICE === row.dosifra);
  if (fromIndex < 0 || toIndex <= fromIndex
    || stops.filter((stop) => stop.sifrA_STANICE === row.odsifra).length !== 1
    || stops.filter((stop) => stop.sifrA_STANICE === row.dosifra).length !== 1
    || stops[fromIndex]!.vremE_POLASKA !== row.vremep
    || stops[toIndex]!.vremE_DOLASKA !== row.vremed
    || stops.some((stop, index) => stop.iD_VOZ !== row.idvoz
      || stop.sifrA_STANICE >= 100_000
      || (index > 0 && stop.rb <= stops[index - 1]!.rb))) throw new Error("Invalid Srbijavoz route");

  let previous = -1;
  let day = 0;
  const advance = (clock: string) => {
    const minutes = srbijaVozClockMinutes(clock);
    if (minutes + day * 1440 < previous) day += 1;
    const result = minutes + day * 1440;
    if (previous >= 0 && result - previous > 12 * 60) throw new Error("Invalid Srbijavoz stop interval");
    previous = result;
    return result;
  };
  const logical = stops.map((stop) => ({
    arrival: advance(stop.vremE_DOLASKA), departure: advance(stop.vremE_POLASKA),
  }));
  const originDay = Math.floor(logical[fromIndex]!.departure / 1440);
  const instant = (minutes: number) => srbijaVozInstant(
    shiftSrbijaVozDate(serviceDate, Math.floor(minutes / 1440) - originDay),
    `${String(Math.floor(minutes % 1440 / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`,
  );
  const times = logical.map((stop) => ({ arrival: instant(stop.arrival), departure: instant(stop.departure) }));
  const flattened = times.flatMap((stop) => [Date.parse(stop.arrival), Date.parse(stop.departure)]);
  if (flattened.some((value, index) => index > 0 && value < flattened[index - 1]!)
    || flattened.at(-1)! - flattened[0]! > 36 * 60 * 60_000) throw new Error("Invalid Srbijavoz chronology");
  const arrivalDate = row.datum_dolaska.slice(0, 10);
  if (!validSrbijaVozDate(arrivalDate)
    || times[toIndex]!.arrival !== srbijaVozInstant(arrivalDate, row.vremed)) throw new Error("Invalid Srbijavoz arrival date");
  const [hours, minutes] = row.trajanje_putovanja.split(":").map(Number) as [number, number];
  const duration = (Date.parse(times[toIndex]!.arrival) - Date.parse(times[fromIndex]!.departure)) / 60_000;
  if (duration <= 0 || duration > 12 * 60 || duration !== hours * 60 + minutes) throw new Error("Invalid Srbijavoz duration");
  return times;
}

function journeyCall(stop: StopSnapshot, position: "from" | "to" | "intermediate"): JourneyCallSnapshot | null {
  const station = srbijaVozStation(stop.stationId.split(":").at(-1)!);
  if (station === undefined) return null;
  return {
    place: srbijaVozPlace(station), city: null,
    scheduledArrival: position === "from" ? null : stop.scheduledArrival,
    scheduledDeparture: position === "to" ? null : stop.scheduledDeparture,
    expectedArrival: null, expectedDeparture: null,
    plannedPlatform: null, expectedPlatform: null, isCancelled: false,
  };
}

export function mapSrbijaVozConnection(
  row: SrbijaVozConnection,
  serviceDate: string,
  fetchedAt: string,
): SrbijaVozMappedConnection | null {
  if (!isSrbijaVozMainline(row)) return null;
  try {
    const times = routeTimes(row, serviceDate);
    const reference = srbijaVozTripReference({
      serviceDate, trainId: row.idvoz, trainNumber: row.brvoz,
      from: row.odsifra, to: row.dosifra, departure: row.vremep,
    });
    const stops: StopSnapshot[] = row.etTrasaVoza.map((stop, index) => {
      const station = srbijaVozStation(stop.sifrA_STANICE);
      return {
        stationId: `rs:srbijavoz:${stop.sifrA_STANICE}`, stationName: stop.naziV_STANICE,
        // Štrpci is the domestic-tariff station on the short Bosnian section.
        // International station namespaces are excluded by routeTimes above.
        countryCode: stop.sifrA_STANICE === 15707 ? "BA" : "RS",
        latitude: station?.latitude ?? null, longitude: station?.longitude ?? null,
        sequence: index + 1,
        scheduledArrival: index === 0 ? null : times[index]!.arrival,
        scheduledDeparture: index === row.etTrasaVoza.length - 1 ? null : times[index]!.departure,
        expectedArrival: null, expectedDeparture: null, plannedPlatform: null, expectedPlatform: null,
        platformSource: null, platformObservedAt: null, cancelled: false, passed: false,
      };
    });
    const fromIndex = row.etTrasaVoza.findIndex((stop) => stop.sifrA_STANICE === row.odsifra);
    const toIndex = row.etTrasaVoza.findIndex((stop) => stop.sifrA_STANICE === row.dosifra);
    const from = journeyCall(stops[fromIndex]!, "from");
    const to = journeyCall(stops[toIndex]!, "to");
    if (from === null || to === null) return null;
    const startTime = times[fromIndex]!.departure;
    const endTime = times[toIndex]!.arrival;
    const product = `${row.soko ? "Soko " : ""}${row.rangs} ${row.brvoz}`;
    const snapshot: TripSnapshot = {
      ...reference, operatorName: "Srbijavoz", product,
      headsign: stops.at(-1)!.stationName, fetchedAt, stops, alertIds: [],
    };
    const fingerprint = `journey-v1-${createHash("sha256")
      .update(JSON.stringify([reference.id, from.place.id, to.place.id, startTime, endTime])).digest("hex")}`;
    const option: JourneyOptionSnapshot = {
      id: `journey-option-${fingerprint.slice(-24)}`, fingerprint,
      startTime, endTime, duration: (Date.parse(endTime) - Date.parse(startTime)) / 1000,
      transferCount: 0,
      segments: [{
        id: `journey-segment-${fingerprint.slice(-24)}`, kind: "rail", walk: null,
        rail: {
          tripId: reference.id, serviceDate, operatorName: snapshot.operatorName, product,
          trainNumber: String(row.brvoz), trainName: row.soko ? "Soko" : null,
          from, to,
          intermediateCalls: stops.slice(fromIndex + 1, toIndex)
            .map((stop) => journeyCall(stop, "intermediate")).filter((call) => call !== null),
          isCancelled: false, isRealtime: false, isTrackable: true, untrackableReason: null,
        },
      }],
      badges: ["direct", "fewestChanges"],
      trackability: { trackableRailSegments: 1, totalRailSegments: 1 },
      realtimeFreshness: null, attributions: [...srbijaVozAttributions], trackingToken: "",
    };
    return { snapshot, option };
  } catch {
    return null;
  }
}

import { countryBoundaries, type BoundaryPoint, type CountryPolygon } from "./country-boundaries.generated.js";
import { ExpiringCache } from "./expiring-cache.js";

const boundaryUncertaintyMeters = 1_000;
const countryCache = new ExpiringCache<string>(2_048);

function contains([longitude, latitude]: BoundaryPoint, ring: readonly BoundaryPoint[]): boolean {
  let inside = false;
  for (let index = 0, previous = ring.length - 1; index < ring.length; previous = index++) {
    const [x1, y1] = ring[index]!;
    const [x2, y2] = ring[previous]!;
    const crosses = (y1 > latitude) !== (y2 > latitude)
      && longitude < ((x2 - x1) * (latitude - y1)) / (y2 - y1) + x1;
    if (crosses) inside = !inside;
  }
  return inside;
}

function nearBoundary([longitude, latitude]: BoundaryPoint, rings: CountryPolygon["rings"]): boolean {
  const longitudeScale = 111_320 * Math.cos(latitude * Math.PI / 180);
  const latitudeScale = 111_320;
  return rings.some((ring) => ring.some((point, index) => {
    const next = ring[(index + 1) % ring.length]!;
    const x = (point[0] - longitude) * longitudeScale;
    const y = (point[1] - latitude) * latitudeScale;
    const dx = (next[0] - point[0]) * longitudeScale;
    const dy = (next[1] - point[1]) * latitudeScale;
    const lengthSquared = dx * dx + dy * dy;
    const fraction = lengthSquared === 0 ? 0 : Math.max(0, Math.min(1, -(x * dx + y * dy) / lengthSquared));
    return Math.hypot(x + fraction * dx, y + fraction * dy) < boundaryUncertaintyMeters;
  }));
}

function locatedCountryCode(sourceCountryCode: string, latitude: number, longitude: number): string {
  const point: BoundaryPoint = [longitude, latitude];
  for (const country of countryBoundaries) {
    for (const polygon of country.polygons) {
      const [west, south, east, north] = polygon.bounds;
      if (longitude < west || longitude > east || latitude < south || latitude > north) continue;
      if (!contains(point, polygon.rings[0]!) || polygon.rings.slice(1).some((ring) => contains(point, ring))) continue;
      // These map boundaries are generalized, including coastlines. Preserve
      // existing evidence in the uncertainty band; named border/coastal stations
      // require separate station evidence, not a smaller global tolerance.
      return country.countryCode === sourceCountryCode || !nearBoundary(point, polygon.rings)
        ? country.countryCode : sourceCountryCode;
    }
  }
  return sourceCountryCode;
}

export function physicalCountryCode(sourceCountryCode: string, latitude: number, longitude: number): string {
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)
    || Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return sourceCountryCode;
  const key = `${sourceCountryCode}:${latitude}:${longitude}`;
  const now = Date.now();
  const cached = countryCache.get(key, now);
  if (cached !== undefined) return cached;
  const country = locatedCountryCode(sourceCountryCode, latitude, longitude);
  countryCache.set(key, country, now, 24 * 60 * 60_000);
  return country;
}

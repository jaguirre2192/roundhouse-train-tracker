export interface PolylineCoordinate {
  latitude: number;
  longitude: number;
}

function encodeComponent(value: number): string {
  let encoded = value < 0 ? ~(value << 1) : value << 1;
  let result = "";
  while (encoded >= 0x20) {
    result += String.fromCharCode((0x20 | (encoded & 0x1f)) + 63);
    encoded >>= 5;
  }
  return result + String.fromCharCode(encoded + 63);
}

export function encodePolyline5(coordinates: readonly PolylineCoordinate[]): string {
  let previousLatitude = 0;
  let previousLongitude = 0;
  let result = "";
  for (const coordinate of coordinates) {
    const latitude = Math.round(coordinate.latitude * 100_000);
    const longitude = Math.round(coordinate.longitude * 100_000);
    result += encodeComponent(latitude - previousLatitude);
    result += encodeComponent(longitude - previousLongitude);
    previousLatitude = latitude;
    previousLongitude = longitude;
  }
  return result;
}

export function decodePolyline5(
  encoded: string,
  expectedCount: number,
): PolylineCoordinate[] | null {
  const coordinates: PolylineCoordinate[] = [];
  let index = 0;
  let latitude = 0;
  let longitude = 0;
  const component = (): number | null => {
    let result = 0;
    let shift = 0;
    while (index < encoded.length && shift <= 30) {
      const byte = encoded.charCodeAt(index) - 63;
      index += 1;
      if (byte < 0 || byte > 63) return null;
      result |= (byte & 0x1f) << shift;
      if (byte < 0x20) return (result & 1) === 1 ? ~(result >> 1) : result >> 1;
      shift += 5;
    }
    return null;
  };
  while (index < encoded.length && coordinates.length < expectedCount) {
    const latitudeDelta = component();
    const longitudeDelta = component();
    if (latitudeDelta === null || longitudeDelta === null) return null;
    latitude += latitudeDelta;
    longitude += longitudeDelta;
    coordinates.push({ latitude: latitude / 100_000, longitude: longitude / 100_000 });
  }
  return index === encoded.length && coordinates.length === expectedCount ? coordinates : null;
}

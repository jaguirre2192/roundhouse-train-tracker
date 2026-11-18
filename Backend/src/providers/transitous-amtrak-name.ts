/** MOTIS can display just "281" while Amtrak's GTFS long name identifies the service.
 * Several named trains use the Hudson line. A corridor or train number alone is ambiguous. */
export function publishedAmtrakName(leg: {
  agencyName?: string | null;
  tripId?: string | null;
  routeLongName?: string | null;
  displayName?: string | null;
  tripShortName?: string | null;
}): string | null {
  const isAmtrak = /\bamtrak\b/i.test(leg.agencyName ?? "") || /(?:^|_)us-amtrak_/i.test(leg.tripId ?? "");
  const route = leg.routeLongName?.trim();
  const number = leg.displayName?.trim() || leg.tripShortName?.trim();
  if (!isAmtrak || !route || !/\p{L}/u.test(route) || !number || !/^\d{1,4}$/.test(number)) return null;
  return route.split(/\s+/).at(-1) === number ? route : [route, number].join(" ");
}

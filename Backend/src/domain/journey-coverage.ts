// Explicitly mirrors connected verified/partial mainline coverage. Planned and
// not-applicable countries are intentionally absent from journey planning.
export const journeyPlanningCountryCodes: ReadonlySet<string> = new Set([
  "US",
  "AM", "AT", "AZ", "BE", "BG", "CH", "CZ", "DE", "DK", "EE", "ES", "FI", "FR", "GB",
  "GE", "GR", "HR", "HU", "IE", "IT", "LI", "LT", "LU", "LV", "MC", "MD", "ME",
  "MK", "NL", "NO", "PL", "PT", "RO", "RS", "SE", "SI", "SK", "UA", "XK",
  "JP",
  "AU", "CA", "IL", "IN", "MA", "MY", "TH",
]);

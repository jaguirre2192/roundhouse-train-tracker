// Entirely invented sample data for testing local times and operator publication checks.
export const syntheticChepeSchedule = JSON.stringify({
  validFrom: "2025-01-01",
  validThrough: "2030-12-31",
  publicationSignatures: ["roundhouse test bulletin", "revision silver"],
  routes: [{
    nativeId: "express-los-mochis-creel",
    headsign: "Creel",
    operatingDays: [4, 6],
    suspensions: [{ months: [5, 10], weekdays: [4] }],
    stops: [
      { stationId: "los-mochis", time: "10:11:00" },
      { stationId: "bahuichivo", time: "11:42:00" },
      { stationId: "creel", time: "16:37:00" },
    ],
  }],
});

export const syntheticChepePublication = "<h1>Roundhouse test bulletin</h1><p>Revision Silver</p>";

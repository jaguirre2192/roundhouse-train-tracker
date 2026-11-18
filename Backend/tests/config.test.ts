import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";

const privateKey = "-----BEGIN PRIVATE KEY-----\ntest\n-----END PRIVATE KEY-----\n";

describe("loadConfig", () => {
  it("decodes a hosted base64 APNs secret and keeps separate platform topics", async () => {
    const config = await loadConfig({
      APNS_MODE: "live",
      APNS_TEAM_ID: "EXAMPLETEAM",
      APNS_KEY_ID: "ABC123DEFG",
      APNS_PRIVATE_KEY_BASE64: Buffer.from(privateKey).toString("base64"),
      APNS_IOS_BUNDLE_ID: "com.jorgeaguirre.TrainTracker",
      APNS_MACOS_BUNDLE_ID: "com.jorgeaguirre.TrainTracker.mac",
      EKISPERT_API_KEY: "licensed-key",
      TDX_CLIENT_ID: "tdx-client",
      TDX_CLIENT_SECRET: "tdx-secret",
      DB_TIMETABLES_CLIENT_ID: "db-client",
      DB_TIMETABLES_API_KEY: "db-key",
      NS_SUBSCRIPTION_KEY: "ns-key",
      SWISS_GTFS_RT_TOKEN: "swiss-token",
      TFNSW_API_TOKEN: "tfnsw-token",
      VIC_GTFS_RT_API_KEY: "vic-key",
      MOBILITEIT_LU_ACCESS_ID: "luxembourg-key",
      PKP_PLK_ENABLED: "true",
      PKP_PLK_API_KEY: "plk-key",
      TRANSLINK_NI_API_TOKEN: "translink-token",
      NIR_TIGER_API_KEY: "nir-key",
      TRAFIKLAB_GTFS_SWEDEN_RT_API_KEY: "trafiklab-key",
      TRAFIKLAB_GTFS_REGIONAL_RT_API_KEY: "trafiklab-regional-key",
      TRAFIKLAB_REALTIME_API_KEY: "trafiklab-platform-key",
      NORTH_AMERICAN_INTERCITY_GTFS_GEOMETRY_OPERATORS: "brightline,via,amtrak,brightline",
      JOURNEY_TOKEN_SECRET: "local-journey-secret-with-32-characters",
    });

    expect(config.apns.privateKey).toBe(privateKey);
    expect(config.apns.topics).toEqual({
      ios: "com.jorgeaguirre.TrainTracker",
      macos: "com.jorgeaguirre.TrainTracker.mac",
    });
    expect(config.ekispertApiKey).toBe("licensed-key");
    expect(config.tdxCredentials).toEqual({ clientId: "tdx-client", clientSecret: "tdx-secret" });
    expect(config.dbTimetablesCredentials).toEqual({ clientId: "db-client", apiKey: "db-key" });
    expect(config.nsSubscriptionKey).toBe("ns-key");
    expect(config.swissGTFSRTToken).toBe("swiss-token");
    expect(config.tfNSWAPIToken).toBe("tfnsw-token");
    expect(config.vicGTFSRTAPIKey).toBe("vic-key");
    expect(config.mobiliteitLuAccessId).toBe("luxembourg-key");
    expect(config.pkpPLKEnabled).toBe(true);
    expect(config.pkpPLKAPIKey).toBe("plk-key");
    expect(config.translinkNIApiToken).toBe("translink-token");
    expect(config.nirTigerAPIKey).toBe("nir-key");
    expect(config.trafiklabGTFSSwedenRTAPIKey).toBe("trafiklab-key");
    expect(config.trafiklabGTFSRegionalRTAPIKey).toBe("trafiklab-regional-key");
    expect(config.trafiklabRealtimeAPIKey).toBe("trafiklab-platform-key");
    expect(config.northAmericanIntercityGTFSGeometryOperators).toEqual(["amtrak", "brightline", "via"]);
    expect(config.journeyTokenSecret).toBe("local-journey-secret-with-32-characters");
  });

  it("accepts escaped newlines from a hosted plaintext secret", async () => {
    const config = await loadConfig({
      APNS_MODE: "live",
      APNS_TEAM_ID: "EXAMPLETEAM",
      APNS_KEY_ID: "ABC123DEFG",
      APNS_PRIVATE_KEY: privateKey.replaceAll("\n", "\\n"),
    });

    expect(config.apns.privateKey).toBe(privateKey);
  });

  it("rejects a partial DB Timetables credential pair", async () => {
    await expect(loadConfig({ DB_TIMETABLES_CLIENT_ID: "db-client" }))
      .rejects.toThrow("DB_TIMETABLES_CLIENT_ID and DB_TIMETABLES_API_KEY must be configured together");
  });

  it("requires at least 32 characters before enabling local journey routes", async () => {
    await expect(loadConfig({})).resolves.toMatchObject({
      journeyTokenSecret: null,
      northAmericanIntercityGTFSGeometryOperators: [],
      amtrakNTADRouteGeometryEnabled: false,
    });
    await expect(loadConfig({ AMTRAK_NTAD_ROUTE_GEOMETRY_ENABLED: "true" }))
      .resolves.toMatchObject({ amtrakNTADRouteGeometryEnabled: true });
    await expect(loadConfig({ JOURNEY_TOKEN_SECRET: "x".repeat(31) }))
      .resolves.toMatchObject({ journeyTokenSecret: null });
    await expect(loadConfig({ JOURNEY_TOKEN_SECRET: "x".repeat(32) }))
      .resolves.toMatchObject({ journeyTokenSecret: "x".repeat(32) });
  });

  it("rejects unsupported intercity geometry operators", async () => {
    await expect(loadConfig({ NORTH_AMERICAN_INTERCITY_GTFS_GEOMETRY_OPERATORS: "amtrak,viarail" }))
      .rejects.toThrow(/NORTH_AMERICAN_INTERCITY_GTFS_GEOMETRY_OPERATORS/u);
  });
});

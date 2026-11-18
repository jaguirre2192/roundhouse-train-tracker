import { readFile } from "node:fs/promises";
import { z } from "zod";
import {
  northAmericanIntercityOperatorsFromAllowlist,
  type NorthAmericanIntercityOperator,
} from "./providers/north-american-intercity-gtfs-model.js";

const booleanString = z.enum(["true", "false"]).transform((value) => value === "true");

const schema = z.object({
  PORT: z.coerce.number().int().positive().default(8080),
  DATABASE_URL: z.string().min(1).default("postgres://traintracker:traintracker@localhost:5432/traintracker"),
  DATABASE_SSL: booleanString.default(false),
  LOG_LEVEL: z.enum(["fatal", "error", "warn", "info", "debug", "trace", "silent"]).default("info"),
  WATCHER_ENABLED: booleanString.default(true),
  MOTIS_BASE_URL: z.string().default(""),
  CHEPE_TIMETABLE_JSON: z.string().optional(),
  APNS_MODE: z.enum(["live", "dry-run"]).default("dry-run"),
  APNS_TEAM_ID: z.string().default(""),
  APNS_KEY_ID: z.string().default(""),
  APNS_IOS_BUNDLE_ID: z.string().default("com.jorgeaguirre.TrainTracker"),
  APNS_MACOS_BUNDLE_ID: z.string().default("com.jorgeaguirre.TrainTracker.mac"),
  APNS_PRIVATE_KEY: z.string().default(""),
  APNS_PRIVATE_KEY_BASE64: z.string().default(""),
  APNS_PRIVATE_KEY_PATH: z.string().default(""),
  EKISPERT_API_KEY: z.string().default(""),
  GOLEMIO_API_KEY: z.string().default(""),
  TDX_CLIENT_ID: z.string().default(""),
  TDX_CLIENT_SECRET: z.string().default(""),
  DB_TIMETABLES_CLIENT_ID: z.string().default(""),
  DB_TIMETABLES_API_KEY: z.string().default(""),
  NS_SUBSCRIPTION_KEY: z.string().default(""),
  SWISS_GTFS_RT_TOKEN: z.string().default(""),
  TFNSW_API_TOKEN: z.string().default(""),
  VIC_GTFS_RT_API_KEY: z.string().default(""),
  MOBILITEIT_LU_ACCESS_ID: z.string().default(""),
  PKP_PLK_ENABLED: booleanString.default(false),
  PKP_PLK_API_KEY: z.string().default(""),
  TRANSLINK_NI_API_TOKEN: z.string().default(""),
  NIR_TIGER_API_KEY: z.string().default(""),
  TRAFIKLAB_GTFS_SWEDEN_RT_API_KEY: z.string().default(""),
  TRAFIKLAB_GTFS_REGIONAL_RT_API_KEY: z.string().default(""),
  TRAFIKLAB_REALTIME_API_KEY: z.string().default(""),
  SHARE_LINK_SECRET: z.string().default(""),
  JOURNEY_TOKEN_SECRET: z.string().default(""),
  NORTH_AMERICAN_INTERCITY_GTFS_GEOMETRY_OPERATORS: z.string().default(""),
  AMTRAK_NTAD_ROUTE_GEOMETRY_ENABLED: booleanString.default(false),
});

export interface AppConfig {
  port: number;
  databaseUrl: string;
  databaseSSL: boolean;
  logLevel: z.infer<typeof schema>["LOG_LEVEL"];
  watcherEnabled: boolean;
  motisBaseURL: string;
  chepeTimetable?: string | undefined;
  ekispertApiKey: string | null;
  golemioApiKey: string | null;
  tdxCredentials: { clientId: string; clientSecret: string } | null;
  dbTimetablesCredentials: { clientId: string; apiKey: string } | null;
  nsSubscriptionKey: string | null;
  swissGTFSRTToken: string | null;
  tfNSWAPIToken: string | null;
  vicGTFSRTAPIKey: string | null;
  mobiliteitLuAccessId: string | null;
  pkpPLKEnabled: boolean;
  pkpPLKAPIKey: string | null;
  translinkNIApiToken: string | null;
  nirTigerAPIKey: string | null;
  trafiklabGTFSSwedenRTAPIKey: string | null;
  trafiklabGTFSRegionalRTAPIKey: string | null;
  trafiklabRealtimeAPIKey: string | null;
  shareLinkSecret: string | null;
  journeyTokenSecret: string | null;
  northAmericanIntercityGTFSGeometryOperators: NorthAmericanIntercityOperator[];
  /** Amtrak route lines from the federal NTAD route network (public domain). */
  amtrakNTADRouteGeometryEnabled: boolean;
  apns: {
    mode: "live" | "dry-run";
    teamId: string;
    keyId: string;
    topics: {
      ios: string;
      macos: string;
    };
    privateKey: string | null;
  };
}

export async function loadConfig(environment: NodeJS.ProcessEnv = process.env): Promise<AppConfig> {
  const value = schema.parse(environment);
  let privateKey: string | null = null;
  if (value.APNS_PRIVATE_KEY.length > 0) {
    privateKey = value.APNS_PRIVATE_KEY.replaceAll("\\n", "\n");
  } else if (value.APNS_PRIVATE_KEY_BASE64.length > 0) {
    privateKey = Buffer.from(value.APNS_PRIVATE_KEY_BASE64, "base64").toString("utf8");
  } else if (value.APNS_PRIVATE_KEY_PATH.length > 0) {
    privateKey = await readFile(value.APNS_PRIVATE_KEY_PATH, "utf8");
  }

  if (value.APNS_MODE === "live" && (privateKey === null || value.APNS_TEAM_ID === "" || value.APNS_KEY_ID === "")) {
    throw new Error(
      "Live APNs mode requires APNS_TEAM_ID, APNS_KEY_ID, and one APNS private-key source",
    );
  }
  if ((value.TDX_CLIENT_ID.length > 0) !== (value.TDX_CLIENT_SECRET.length > 0)) {
    throw new Error("TDX_CLIENT_ID and TDX_CLIENT_SECRET must be configured together");
  }
  if ((value.DB_TIMETABLES_CLIENT_ID.length > 0) !== (value.DB_TIMETABLES_API_KEY.length > 0)) {
    throw new Error("DB_TIMETABLES_CLIENT_ID and DB_TIMETABLES_API_KEY must be configured together");
  }

  return {
    port: value.PORT,
    databaseUrl: value.DATABASE_URL,
    databaseSSL: value.DATABASE_SSL,
    logLevel: value.LOG_LEVEL,
    watcherEnabled: value.WATCHER_ENABLED,
    motisBaseURL: value.MOTIS_BASE_URL,
    chepeTimetable: value.CHEPE_TIMETABLE_JSON,
    ekispertApiKey: value.EKISPERT_API_KEY.length > 0 ? value.EKISPERT_API_KEY : null,
    golemioApiKey: value.GOLEMIO_API_KEY.trim().length > 0 ? value.GOLEMIO_API_KEY.trim() : null,
    tdxCredentials: value.TDX_CLIENT_ID.length > 0
      ? { clientId: value.TDX_CLIENT_ID, clientSecret: value.TDX_CLIENT_SECRET }
      : null,
    dbTimetablesCredentials: value.DB_TIMETABLES_CLIENT_ID.length > 0
      ? { clientId: value.DB_TIMETABLES_CLIENT_ID, apiKey: value.DB_TIMETABLES_API_KEY }
      : null,
    nsSubscriptionKey: value.NS_SUBSCRIPTION_KEY.length > 0 ? value.NS_SUBSCRIPTION_KEY : null,
    swissGTFSRTToken: value.SWISS_GTFS_RT_TOKEN.length > 0 ? value.SWISS_GTFS_RT_TOKEN : null,
    tfNSWAPIToken: value.TFNSW_API_TOKEN.length > 0 ? value.TFNSW_API_TOKEN : null,
    vicGTFSRTAPIKey: value.VIC_GTFS_RT_API_KEY.length > 0 ? value.VIC_GTFS_RT_API_KEY : null,
    mobiliteitLuAccessId: value.MOBILITEIT_LU_ACCESS_ID.length > 0
      ? value.MOBILITEIT_LU_ACCESS_ID
      : null,
    pkpPLKEnabled: value.PKP_PLK_ENABLED,
    pkpPLKAPIKey: value.PKP_PLK_API_KEY.length > 0 ? value.PKP_PLK_API_KEY : null,
    translinkNIApiToken: value.TRANSLINK_NI_API_TOKEN.length > 0 ? value.TRANSLINK_NI_API_TOKEN : null,
    nirTigerAPIKey: value.NIR_TIGER_API_KEY.length > 0 ? value.NIR_TIGER_API_KEY : null,
    trafiklabGTFSSwedenRTAPIKey: value.TRAFIKLAB_GTFS_SWEDEN_RT_API_KEY.length > 0
      ? value.TRAFIKLAB_GTFS_SWEDEN_RT_API_KEY
      : null,
    trafiklabGTFSRegionalRTAPIKey: value.TRAFIKLAB_GTFS_REGIONAL_RT_API_KEY.length > 0
      ? value.TRAFIKLAB_GTFS_REGIONAL_RT_API_KEY
      : null,
    trafiklabRealtimeAPIKey: value.TRAFIKLAB_REALTIME_API_KEY.length > 0
      ? value.TRAFIKLAB_REALTIME_API_KEY
      : null,
    shareLinkSecret: value.SHARE_LINK_SECRET.length > 0 ? value.SHARE_LINK_SECRET : null,
    journeyTokenSecret: value.JOURNEY_TOKEN_SECRET.length >= 32 ? value.JOURNEY_TOKEN_SECRET : null,
    northAmericanIntercityGTFSGeometryOperators: northAmericanIntercityOperatorsFromAllowlist(
      value.NORTH_AMERICAN_INTERCITY_GTFS_GEOMETRY_OPERATORS,
    ),
    amtrakNTADRouteGeometryEnabled: value.AMTRAK_NTAD_ROUTE_GEOMETRY_ENABLED,
    apns: {
      mode: value.APNS_MODE,
      teamId: value.APNS_TEAM_ID,
      keyId: value.APNS_KEY_ID,
      topics: {
        ios: value.APNS_IOS_BUNDLE_ID,
        macos: value.APNS_MACOS_BUNDLE_ID,
      },
      privateKey,
    },
  };
}

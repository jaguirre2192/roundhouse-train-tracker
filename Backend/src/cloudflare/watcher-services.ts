import { EnturVehiclePositionOverlay } from "../providers/entur-vehicle-position.js";
import { AuthService } from "../auth/auth-service.js";
import { ForwardingService } from "../forwarding/forwarding-service.js";
import { GmailInboxService } from "../gmail/gmail-service.js";
import { AmtrakerProvider } from "../providers/amtraker.js";
import { northAmericanRouteGeometrySource } from "../providers/north-american-route-geometry.js";
import { northAmericanIntercityOperatorsFromAllowlist } from "../providers/north-american-intercity-gtfs-model.js";
import { CpRealtimeOverlay } from "../providers/cp-realtime.js";
import { ChepeProvider } from "../providers/chepe.js";
import { DarwinRealtimeOverlay } from "../providers/darwin-realtime.js";
import { DBTimetablesOverlay } from "../providers/db-timetables.js";
import { DigitrafficPlatformOverlay } from "../providers/digitraffic.js";
import { EkispertProvider } from "../providers/ekispert.js";
import { ElronRealtimeOverlay } from "../providers/elron-realtime.js";
import { EnturPlatformOverlay } from "../providers/entur.js";
import { IrishRailRealtimeOverlay } from "../providers/irish-rail-realtime.js";
import { IRailPlatformOverlay } from "../providers/irail.js";
import { MalaysiaVehiclePositionOverlay } from "../providers/malaysia-vehicle-position.js";
import { MobiliteitLuRealtimeOverlay } from "../providers/mobiliteit-lu.js";
import { NSRealtimeOverlay } from "../providers/ns-realtime.js";
import { OebbInfoToGoOverlay } from "../providers/oebb-infotogo.js";
import { PKPPLKRealtimeOverlay } from "../providers/pkp-plk-realtime.js";
import { TripSnapshotEnricher } from "../providers/platform-overlay.js";
import { ProviderRegistry } from "../providers/provider.js";
import { RenfePlatformOverlay } from "../providers/renfe.js";
import { SncfRealtimeOverlay } from "../providers/sncf-realtime.js";
import { SwissRealtimeOverlay } from "../providers/swiss-realtime.js";
import { TdxProvider } from "../providers/tdx.js";
import { enrichTaiwanMirrorBoard, enrichTaiwanMirrorTrip } from "../providers/taiwan-gtfs-realtime.js";
import { TfNSWVehiclePositionOverlay } from "../providers/tfnsw-vehicle-position.js";
import { TfNSWRealtimeOverlay } from "../providers/tfnsw-realtime.js";
import { configuredMotis } from "../providers/configured-motis.js";
import type { TransitousProvider } from "../providers/transitous.js";
import { MainlineJourneyProvider } from "../providers/mainline-journeys.js";
import { SrbijaVozProvider } from "../providers/srbijavoz-provider.js";
import { SQLiteSrbijaVozSnapshotStore } from "./srbijavoz-snapshot-store.js";
import { TranslinkNIOpendataOverlay } from "../providers/translink-ni-api.js";
import { TranslinkNIRRealtimeOverlay } from "../providers/translink-nir-realtime.js";
import { TrafiklabSwedenRealtimeOverlay } from "../providers/trafiklab-sweden-realtime.js";
import { TrafiklabSwedenTimetableOverlay } from "../providers/trafiklab-sweden-timetables.js";
import { ViaRailVehiclePositionOverlay } from "../providers/via-rail-vehicle-position.js";
import { AmtrakerVehiclePositionOverlay } from "../providers/amtraker-vehicle-position.js";
import { GolemioRealtimeOverlay } from "../providers/golemio-realtime.js";
import { PieturasViviPositionOverlay } from "../providers/pieturas-vivi-positions.js";
import { ProviderRequestPacer } from "../providers/provider-request-pacer.js";
import { VLineRealtimeOverlay } from "../providers/vline-realtime.js";
import { WatcherCycle, type WatcherLogger } from "../worker/watcher-cycle.js";
import { JourneySearchService } from "../services/journey-search-service.js";
import type { JourneyMetricLogger } from "../services/journey-metrics.js";
import { PlatformCorpusSampler } from "../services/platform-corpus-sampler.js";
import { authEncryptionKey } from "./auth-config.js";
import { CloudflareAPNsSender } from "./apns-sender.js";
import { DarwinFTPFeed } from "./darwin-ftp.js";
import type { WorkerEnv } from "./env.js";
import { forwardingDomain } from "./forwarding-config.js";
import { watcherStorage } from "./watcher-storage.js";
import { SQLiteWatcherRepository } from "./sqlite-repository.js";
import { LiveActivityService } from "./live-activity-service.js";
import { CloudflareLiveActivitySender } from "./live-activity-sender.js";
import { TrafiklabRegionalMaintainedOverlay } from "../providers/trafiklab-regional-maintained-overlay.js";
import { trafiklabSkaneRailIndex } from "../providers/trafiklab-skane-index.generated.js";
import { trafiklabRegionalSilverPolicy as regionalPolicy } from "../providers/trafiklab-regional-policy.js";
import { ProviderRequestBudget } from "./provider-request-budget.js";
import { tdxBudgetedFetch } from "./tdx-budgeted-fetch.js";
import { RailIndexStore } from "./rail-index-store.js";
import { RegionalFeedStore } from "./regional-feed-store.js";
import type { CoverageConfiguration } from "../domain/trip-coverage.js";
import { GTFSRailIndexStore } from "./mainline-gtfs-store.js";
import { StaticGTFSProvider } from "../providers/mainline-gtfs-provider.js";
import { GTFSDiscoveryProvider, GTFSJourneyProvider } from "../providers/mainline-gtfs-routing.js";
import { KorailRealtime } from "../providers/korail-realtime.js";
import { DenmarkSiriStore } from "./denmark-siri-store.js";
import { DenmarkSiriOverlay } from "../providers/denmark-siri-overlay.js";

export interface WatcherServices {
  storage: DurableObjectStorage;
  repository: SQLiteWatcherRepository;
  providers: ProviderRegistry;
  cycle: WatcherCycle;
  liveActivities: LiveActivityService;
  gmail: GmailInboxService | null;
  auth: AuthService | null;
  forwarding: ForwardingService;
  darwin: DarwinFTPFeed | null;
  trafiklabRegional: TrafiklabRegionalMaintainedOverlay | null;
  journey: JourneySearchService | null;
  platformSampler: PlatformCorpusSampler | null;
}

const logger: WatcherLogger = {
  info(data, message) { console.info(message ?? "watcher", data); },
  error(data, message) { console.error(message ?? "watcher", data); },
};

const journeyMetricLogger: JourneyMetricLogger = {
  log(metric) { console.info("journey_metric", metric); },
};

function required(value: string | undefined, name: string, mode: "live" | "dry-run"): string {
  if (value !== undefined && value.length > 0) return value;
  if (mode === "dry-run") return "dry-run";
  throw new Error(`${name} must be configured for live APNs delivery`);
}

function createDarwinFeed(storage: DurableObjectStorage, env: WorkerEnv): DarwinFTPFeed | null {
  if (env.DARWIN_FTP_HOST === undefined || env.DARWIN_FTP_HOST.length === 0
    || env.DARWIN_FTP_USERNAME === undefined || env.DARWIN_FTP_USERNAME.length === 0
    || env.DARWIN_FTP_PASSWORD === undefined || env.DARWIN_FTP_PASSWORD.length === 0
    || env.DARWIN_FTP_MESSAGES_DIRECTORY === undefined || env.DARWIN_FTP_MESSAGES_DIRECTORY.length === 0
    || env.DARWIN_FTP_SNAPSHOT_DIRECTORY === undefined || env.DARWIN_FTP_SNAPSHOT_DIRECTORY.length === 0) {
    return null;
  }

  return new DarwinFTPFeed({
    host: env.DARWIN_FTP_HOST,
    username: env.DARWIN_FTP_USERNAME,
    password: env.DARWIN_FTP_PASSWORD,
    messagesDirectory: env.DARWIN_FTP_MESSAGES_DIRECTORY,
    snapshotDirectory: env.DARWIN_FTP_SNAPSHOT_DIRECTORY,
  }, storage);
}

function createProviderRegistries(
  env: WorkerEnv,
  darwin: DarwinFTPFeed | null,
  serbia: SrbijaVozProvider,
  motisDiscovery: TransitousProvider,
  storage: DurableObjectStorage,
  waitUntil: (work: Promise<unknown>) => void,
): { interactive: ProviderRegistry; watcher: ProviderRegistry; regional: TrafiklabRegionalMaintainedOverlay | null;
  coverage: CoverageConfiguration; gtfs: StaticGTFSProvider[] } {
  const korail = new KorailRealtime();
  const tdx = env.TDX_CLIENT_ID && env.TDX_CLIENT_SECRET
    ? new TdxProvider(env.TDX_CLIENT_ID, env.TDX_CLIENT_SECRET, undefined, undefined, tdxBudgetedFetch(storage))
    : null;
  const gtfs = [new StaticGTFSProvider("TW", () => new GTFSRailIndexStore(storage, "TW").load(),
    tdx === null ? {} : {
      realtime: snapshot => enrichTaiwanMirrorTrip(snapshot, reference => tdx.fetchTrip(reference, { includeStationCoordinates: false })),
      realtimeBoard: (entries, station) => enrichTaiwanMirrorBoard(entries, station, reference => tdx.fetchBoard(reference)),
    }),
    new StaticGTFSProvider("KR",() => new GTFSRailIndexStore(storage,"KR").load(),{ realtime: (snapshot,index,trip) => korail.enrich(snapshot,index,trip) })];
  const enabledNorthAmericanIntercityOperators = northAmericanIntercityOperatorsFromAllowlist(
    env.NORTH_AMERICAN_INTERCITY_GTFS_GEOMETRY_OPERATORS ?? "",
  );
  const northAmericanIntercityGeometry = northAmericanRouteGeometrySource({
    gtfsOperators: enabledNorthAmericanIntercityOperators,
    amtrakNTADRoutes: env.AMTRAK_NTAD_ROUTE_GEOMETRY_ENABLED === "true",
  });
  const discoveryProviders = [
    new AmtrakerProvider(undefined, undefined, undefined, northAmericanIntercityGeometry),
    ...(env.EKISPERT_API_KEY === undefined || env.EKISPERT_API_KEY.length === 0
      ? []
      : [new EkispertProvider(env.EKISPERT_API_KEY)]),
    ...(tdx === null ? [] : [tdx]),
    new ChepeProvider(undefined, undefined, env.CHEPE_TIMETABLE_JSON),
    serbia,
    new GTFSDiscoveryProvider(motisDiscovery, gtfs),
  ];
  // Taiwan station autocomplete runs entirely on the published index. The
  // direct provider remains available to existing TDX boards and saved trains.
  const stationSearchProviders = discoveryProviders.filter(provider => provider !== tdx);
  const renfe = new RenfePlatformOverlay();
  // Keep the existing ledger when using the approved Regional Silver quota.
  // Independent lane cooldowns let timings and positions refresh in one poll.
  const regionalBudget = new ProviderRequestBudget(
    storage, "provider-quota:trafiklab-regional-skane:v1", regionalPolicy.rollingRequestCap,
    regionalPolicy.sharedMinimumIntervalMilliseconds, Date.now, regionalPolicy.laneMinimumIntervalMilliseconds,
  );
  const regionalIndex = new RailIndexStore(storage);
  const regionalFeed = new RegionalFeedStore(storage);
  const regionalPositions = new RegionalFeedStore(storage, "regional-feed:trafiklab-skane:positions");
  const regional = env.TRAFIKLAB_GTFS_REGIONAL_RT_API_KEY
    ? new TrafiklabRegionalMaintainedOverlay(env.TRAFIKLAB_GTFS_REGIONAL_RT_API_KEY, {
      bundledIndex: trafiklabSkaneRailIndex, reserveRequest: () => regionalBudget.reserve("trip-updates"),
      minimumFetchIntervalMilliseconds: regionalPolicy.minimumFetchIntervalMilliseconds,
      loadIndex: () => regionalIndex.load(),
      readFeed: () => regionalFeed.load(), writeFeed: (value) => regionalFeed.save(value),
      reservePositionRequest: () => regionalBudget.reserve("positions"),
      readPositionFeed: () => regionalPositions.load(), writePositionFeed: (value) => regionalPositions.save(value),
    }) : null;
  const cp = env.CP_REALTIME_API_KEY !== undefined && env.CP_REALTIME_API_KEY.length > 0
    && env.CP_REALTIME_CONNECT_ID !== undefined && env.CP_REALTIME_CONNECT_ID.length > 0
    && env.CP_REALTIME_CONNECT_SECRET !== undefined && env.CP_REALTIME_CONNECT_SECRET.length > 0
    ? new CpRealtimeOverlay(
      env.CP_REALTIME_API_KEY,
      env.CP_REALTIME_CONNECT_ID,
      env.CP_REALTIME_CONNECT_SECRET,
    )
    : null;
  const irishRail = new IrishRailRealtimeOverlay();
  const elron = new ElronRealtimeOverlay();
  const amtraker = new AmtrakerVehiclePositionOverlay();
  const golemioBudget = new ProviderRequestBudget(storage, "provider-quota:golemio:v1", Number.MAX_SAFE_INTEGER, 500);
  const golemioPacer = new ProviderRequestPacer(() => golemioBudget.reserve());
  const golemio = env.GOLEMIO_API_KEY?.trim()
    ? new GolemioRealtimeOverlay(env.GOLEMIO_API_KEY.trim(), { reserveRequest: () => golemioPacer.wait() }) : null;
  const malaysiaBudget = new ProviderRequestBudget(storage, "provider-quota:malaysia-ktmb:v1", Number.MAX_SAFE_INTEGER, 30_000);
  const malaysiaFeed = new RegionalFeedStore(storage, "provider-feed:malaysia-ktmb:v1");
  const malaysia = new MalaysiaVehiclePositionOverlay(undefined, undefined, undefined, {
    reserveRequest: () => malaysiaBudget.reserve(),
    deferRequestUntil: (until) => malaysiaBudget.deferUntil(until),
    readFeed: () => malaysiaFeed.load(), writeFeed: (value) => malaysiaFeed.save(value),
  });
  const sncf = new SncfRealtimeOverlay();
  const digitraffic = new DigitrafficPlatformOverlay();
  const ns = env.NS_SUBSCRIPTION_KEY ? new NSRealtimeOverlay(env.NS_SUBSCRIPTION_KEY) : null;
  const denmarkSiri = new DenmarkSiriStore(storage);
  const mobiliteitLu = env.MOBILITEIT_LU_ACCESS_ID === undefined
    || env.MOBILITEIT_LU_ACCESS_ID.length === 0
    ? null
    : new MobiliteitLuRealtimeOverlay(env.MOBILITEIT_LU_ACCESS_ID);
  const vLine = env.VIC_GTFS_RT_API_KEY === undefined || env.VIC_GTFS_RT_API_KEY.length === 0
    ? null
    : new VLineRealtimeOverlay(env.VIC_GTFS_RT_API_KEY);
  const trafiklab = env.TRAFIKLAB_GTFS_SWEDEN_RT_API_KEY === undefined
    || env.TRAFIKLAB_GTFS_SWEDEN_RT_API_KEY.length === 0
    ? null
    : new TrafiklabSwedenRealtimeOverlay(env.TRAFIKLAB_GTFS_SWEDEN_RT_API_KEY);
  const realtimeOverlays = [
    amtraker,
    new IRailPlatformOverlay(),
    renfe.timingOverlay,
    renfe,
    digitraffic,
    new EnturPlatformOverlay(),
    sncf.timingOverlay,
    sncf,
    new OebbInfoToGoOverlay(),
    ...(darwin === null ? [] : [new DarwinRealtimeOverlay(darwin)]),
    ...(env.DB_TIMETABLES_CLIENT_ID === undefined || env.DB_TIMETABLES_CLIENT_ID.length === 0
      || env.DB_TIMETABLES_API_KEY === undefined || env.DB_TIMETABLES_API_KEY.length === 0
      ? []
      : [new DBTimetablesOverlay(env.DB_TIMETABLES_CLIENT_ID, env.DB_TIMETABLES_API_KEY)]),
    ...(ns === null ? [] : [ns, ns.arrivalOverlay]),
    ...(env.SWISS_GTFS_RT_TOKEN === undefined || env.SWISS_GTFS_RT_TOKEN.length === 0
      ? []
      : [new SwissRealtimeOverlay(env.SWISS_GTFS_RT_TOKEN)]),
    ...(env.TFNSW_API_TOKEN === undefined || env.TFNSW_API_TOKEN.length === 0
      ? []
      : [new TfNSWRealtimeOverlay(env.TFNSW_API_TOKEN)]),
    ...(vLine === null ? [] : [vLine]),
    ...(env.PKP_PLK_ENABLED !== "true"
      || env.PKP_PLK_API_KEY === undefined || env.PKP_PLK_API_KEY.length === 0
      ? []
      : [new PKPPLKRealtimeOverlay(env.PKP_PLK_API_KEY)]),
    ...(env.TRANSLINK_NI_API_TOKEN !== undefined && env.TRANSLINK_NI_API_TOKEN.length > 0
      ? [new TranslinkNIOpendataOverlay(env.TRANSLINK_NI_API_TOKEN)]
      : env.NIR_TIGER_API_KEY === undefined || env.NIR_TIGER_API_KEY.length === 0
        ? []
        : [new TranslinkNIRRealtimeOverlay(env.NIR_TIGER_API_KEY)]),
    ...(trafiklab === null ? [] : [trafiklab]),
    ...(regional === null ? [] : [regional]),
    ...(env.TRAFIKLAB_REALTIME_API_KEY === undefined || env.TRAFIKLAB_REALTIME_API_KEY.length === 0
      ? []
      : [new TrafiklabSwedenTimetableOverlay(env.TRAFIKLAB_REALTIME_API_KEY)]),
    ...(mobiliteitLu === null ? [] : [mobiliteitLu]),
    elron,
    irishRail,
    new DenmarkSiriOverlay((snapshot, nowISO) => denmarkSiri.readJourneys(snapshot, nowISO)),
  ];
  const positionOverlays = [
    new PieturasViviPositionOverlay(),
    ...(golemio === null ? [] : [golemio]),
    ...(regional === null ? [] : [regional]),
    renfe,
    digitraffic,
    new EnturVehiclePositionOverlay(),
    ...(env.TFNSW_API_TOKEN === undefined || env.TFNSW_API_TOKEN.length === 0
      ? [] : [new TfNSWVehiclePositionOverlay(env.TFNSW_API_TOKEN)]),
    malaysia,
    new ViaRailVehiclePositionOverlay(),
    amtraker,
    elron,
    irishRail,
    ...(vLine === null ? [] : [vLine]),
    ...(cp === null ? [] : [cp]),
    ...(trafiklab === null ? [] : [trafiklab]),
  ];
  const makeEnricher = () => new TripSnapshotEnricher([
    ...realtimeOverlays,
    ...(cp === null ? [] : [cp]),
  ], positionOverlays);

  return {
    interactive: new ProviderRegistry(discoveryProviders, makeEnricher(), waitUntil, stationSearchProviders),
    watcher: new ProviderRegistry(discoveryProviders, makeEnricher(), waitUntil, stationSearchProviders),
    regional,
    gtfs,
    coverage: { enabledSources: new Set([
      ...(tdx === null ? [] : ["tdx"]),
      ...(golemio === null ? [] : ["golemio-pid"]),
      ...(regional === null ? [] : ["trafiklab-regional"]),
      ...(trafiklab === null ? [] : ["trafiklab-national"]),
      ...(env.TRAFIKLAB_REALTIME_API_KEY ? ["trafiklab-timetables"] : []),
      ...(env.DB_TIMETABLES_CLIENT_ID && env.DB_TIMETABLES_API_KEY ? ["db-timetables"] : []),
      ...(env.SWISS_GTFS_RT_TOKEN ? ["swiss"] : []),
      ...(env.TFNSW_API_TOKEN ? ["tfnsw"] : []),
      ...(ns === null ? [] : ["ns"]), ...(darwin === null ? [] : ["darwin"]),
      ...(cp === null ? [] : ["cp"]), ...(mobiliteitLu === null ? [] : ["mobiliteit"]),
      ...(env.PKP_PLK_ENABLED === "true" && env.PKP_PLK_API_KEY ? ["pkp-plk"] : []),
      ...(env.TRANSLINK_NI_API_TOKEN || env.NIR_TIGER_API_KEY ? ["translink-ni"] : []),
    ]) },
  };
}

export function createWatcherServices(ctx: DurableObjectState, env: WorkerEnv): WatcherServices {
  const storage = watcherStorage(ctx.storage);
  const repository = new SQLiteWatcherRepository(storage);
  const mode = env.APNS_MODE ?? "dry-run";
  const sender = new CloudflareAPNsSender({
    mode,
    teamId: required(env.APNS_TEAM_ID, "APNS_TEAM_ID", mode),
    keyId: required(env.APNS_KEY_ID, "APNS_KEY_ID", mode),
    topics: {
      ios: required(env.APNS_IOS_BUNDLE_ID, "APNS_IOS_BUNDLE_ID", mode),
      macos: required(env.APNS_MACOS_BUNDLE_ID, "APNS_MACOS_BUNDLE_ID", mode),
    },
    privateKey: required(env.APNS_PRIVATE_KEY, "APNS_PRIVATE_KEY", mode),
  });
  const darwin = createDarwinFeed(storage, env);
  const serbia = new SrbijaVozProvider({ snapshotStore: new SQLiteSrbijaVozSnapshotStore(storage.sql) });
  const motis = configuredMotis(env.MOTIS_BASE_URL);
  const providers = createProviderRegistries(env, darwin, serbia, motis.discovery, storage, (work) => ctx.waitUntil(work));
  const gmail = env.GMAIL_OAUTH_CLIENT_ID !== undefined
    && env.GMAIL_OAUTH_CLIENT_SECRET !== undefined
    && env.GMAIL_TOKEN_ENCRYPTION_KEY !== undefined
    ? new GmailInboxService(storage, {
      clientId: env.GMAIL_OAUTH_CLIENT_ID,
      clientSecret: env.GMAIL_OAUTH_CLIENT_SECRET,
      tokenEncryptionKey: env.GMAIL_TOKEN_ENCRYPTION_KEY,
      pubSubTopic: env.GMAIL_PUBSUB_TOPIC ?? null,
    })
    : null;
  const resolvedAuthEncryptionKey = authEncryptionKey(env);
  const auth = resolvedAuthEncryptionKey === undefined
    ? null
    : new AuthService(storage, resolvedAuthEncryptionKey);
  const forwarding = new ForwardingService(storage, env.TICKET_FORWARDING_SECRET && env.TICKET_FORWARDING_SECRET.length >= 32
    ? { domain: forwardingDomain(env), secret: env.TICKET_FORWARDING_SECRET } : null);
  const journey = env.JOURNEY_TOKEN_SECRET === undefined || env.JOURNEY_TOKEN_SECRET.length < 32
    ? null
    : new JourneySearchService(
      new GTFSJourneyProvider(new MainlineJourneyProvider(serbia, motis.journeys), providers.gtfs),
      providers.interactive,
      env.JOURNEY_TOKEN_SECRET,
      journeyMetricLogger,
      undefined, undefined, providers.coverage,
    );
  const platformSampler = env.PLATFORM_SAMPLING_ENABLED === "true"
    && env.DB_TIMETABLES_CLIENT_ID !== undefined && env.DB_TIMETABLES_CLIENT_ID.length > 0
    && env.DB_TIMETABLES_API_KEY !== undefined && env.DB_TIMETABLES_API_KEY.length > 0
    ? new PlatformCorpusSampler(repository, providers.watcher)
    : null;

  return {
    storage,
    repository,
    providers: providers.interactive,
    cycle: new WatcherCycle(repository, providers.watcher, sender, logger),
    liveActivities: new LiveActivityService(storage, providers.watcher, new CloudflareLiveActivitySender({
      mode, teamId: required(env.APNS_TEAM_ID, "APNS_TEAM_ID", mode),
      keyId: required(env.APNS_KEY_ID, "APNS_KEY_ID", mode),
      privateKey: required(env.APNS_PRIVATE_KEY, "APNS_PRIVATE_KEY", mode),
      bundleId: required(env.APNS_IOS_BUNDLE_ID, "APNS_IOS_BUNDLE_ID", mode),
    })),
    gmail,
    auth,
    forwarding,
    darwin,
    trafiklabRegional: providers.regional,
    journey,
    platformSampler,
  };
}

import { EnturVehiclePositionOverlay } from "./providers/entur-vehicle-position.js";
import { fileURLToPath } from "node:url";
import { DryRunPushSender, LiveAPNsSender } from "./apns/sender.js";
import { loadConfig } from "./config.js";
import { makeDatabasePool } from "./db/database.js";
import { WatcherRepository } from "./db/repository.js";
import { makeApp } from "./http/app.js";
import { AmtrakerProvider } from "./providers/amtraker.js";
import { northAmericanRouteGeometrySource } from "./providers/north-american-route-geometry.js";
import { ChepeProvider } from "./providers/chepe.js";
import { IRailPlatformOverlay } from "./providers/irail.js";
import { TripSnapshotEnricher } from "./providers/platform-overlay.js";
import { ProviderRegistry } from "./providers/provider.js";
import { RenfePlatformOverlay } from "./providers/renfe.js";
import { configuredMotis } from "./providers/configured-motis.js";
import { MainlineJourneyProvider } from "./providers/mainline-journeys.js";
import { SrbijaVozProvider } from "./providers/srbijavoz-provider.js";
import { PostgresSrbijaVozSnapshotStore } from "./providers/srbijavoz-postgres-store.js";
import { DigitrafficPlatformOverlay } from "./providers/digitraffic.js";
import { EnturPlatformOverlay } from "./providers/entur.js";
import { EkispertProvider } from "./providers/ekispert.js";
import { ElronRealtimeOverlay } from "./providers/elron-realtime.js";
import { TdxProvider } from "./providers/tdx.js";
import { SncfRealtimeOverlay } from "./providers/sncf-realtime.js";
import { DBTimetablesOverlay } from "./providers/db-timetables.js";
import { NSRealtimeOverlay } from "./providers/ns-realtime.js";
import { SwissRealtimeOverlay } from "./providers/swiss-realtime.js";
import { TfNSWVehiclePositionOverlay } from "./providers/tfnsw-vehicle-position.js";
import { TfNSWRealtimeOverlay } from "./providers/tfnsw-realtime.js";
import { VLineRealtimeOverlay } from "./providers/vline-realtime.js";
import { PKPPLKRealtimeOverlay } from "./providers/pkp-plk-realtime.js";
import { IrishRailRealtimeOverlay } from "./providers/irish-rail-realtime.js";
import { TranslinkNIOpendataOverlay } from "./providers/translink-ni-api.js";
import { TranslinkNIRRealtimeOverlay } from "./providers/translink-nir-realtime.js";
import { TrafiklabSwedenRealtimeOverlay } from "./providers/trafiklab-sweden-realtime.js";
import { TrafiklabSwedenTimetableOverlay } from "./providers/trafiklab-sweden-timetables.js";
import { MalaysiaVehiclePositionOverlay } from "./providers/malaysia-vehicle-position.js";
import { MobiliteitLuRealtimeOverlay } from "./providers/mobiliteit-lu.js";
import { OebbInfoToGoOverlay } from "./providers/oebb-infotogo.js";
import { ViaRailVehiclePositionOverlay } from "./providers/via-rail-vehicle-position.js";
import { AmtrakerVehiclePositionOverlay } from "./providers/amtraker-vehicle-position.js";
import { GolemioRealtimeOverlay } from "./providers/golemio-realtime.js";
import { PieturasViviPositionOverlay } from "./providers/pieturas-vivi-positions.js";
import { ProviderRequestPacer } from "./providers/provider-request-pacer.js";
import { JourneySearchService } from "./services/journey-search-service.js";
import type { JourneyMetricLogger } from "./services/journey-metrics.js";
import { Watcher } from "./worker/watcher.js";

const journeyMetricLogger: JourneyMetricLogger = {
  log(metric) { console.info("journey_metric", metric); },
};

export async function start(): Promise<void> {
  const config = await loadConfig();
  const pool = makeDatabasePool(config.databaseUrl, config.databaseSSL);
  const repository = new WatcherRepository(pool);
  const northAmericanIntercityGeometry = northAmericanRouteGeometrySource({
    gtfsOperators: config.northAmericanIntercityGTFSGeometryOperators,
    amtrakNTADRoutes: config.amtrakNTADRouteGeometryEnabled,
  });
  const serbia = new SrbijaVozProvider({ snapshotStore: new PostgresSrbijaVozSnapshotStore(pool) });
  const motis = configuredMotis(config.motisBaseURL);
  const discoveryProviders = [
    new AmtrakerProvider(undefined, undefined, undefined, northAmericanIntercityGeometry),
    ...(config.ekispertApiKey === null ? [] : [new EkispertProvider(config.ekispertApiKey)]),
    ...(config.tdxCredentials === null
      ? []
      : [new TdxProvider(config.tdxCredentials.clientId, config.tdxCredentials.clientSecret)]),
    new ChepeProvider(undefined, undefined, config.chepeTimetable),
    serbia,
    motis.discovery,
  ];
  const dbTimetables = config.dbTimetablesCredentials === null
    ? []
    : [new DBTimetablesOverlay(
      config.dbTimetablesCredentials.clientId,
      config.dbTimetablesCredentials.apiKey,
    )];
  const irishRail = new IrishRailRealtimeOverlay();
  const elron = new ElronRealtimeOverlay();
  const renfe = new RenfePlatformOverlay();
  const amtraker = new AmtrakerVehiclePositionOverlay();
  const golemioPacer = new ProviderRequestPacer();
  const golemio = config.golemioApiKey === null ? null
    : new GolemioRealtimeOverlay(config.golemioApiKey, { reserveRequest: () => golemioPacer.wait() });
  const sncf = new SncfRealtimeOverlay();
  const digitraffic = new DigitrafficPlatformOverlay();
  const ns = config.nsSubscriptionKey === null ? null : new NSRealtimeOverlay(config.nsSubscriptionKey);
  const vLine = config.vicGTFSRTAPIKey === null ? null : new VLineRealtimeOverlay(config.vicGTFSRTAPIKey);
  const mobiliteitLu = config.mobiliteitLuAccessId === null
    ? null
    : new MobiliteitLuRealtimeOverlay(config.mobiliteitLuAccessId);
  const trafiklab = config.trafiklabGTFSSwedenRTAPIKey === null
    ? null
    : new TrafiklabSwedenRealtimeOverlay(config.trafiklabGTFSSwedenRTAPIKey);
  const providers = new ProviderRegistry(
    discoveryProviders,
    new TripSnapshotEnricher([
      amtraker,
      new IRailPlatformOverlay(),
      renfe.timingOverlay,
      renfe,
      digitraffic,
      new EnturPlatformOverlay(),
      sncf.timingOverlay,
      sncf,
      new OebbInfoToGoOverlay(),
      ...dbTimetables,
      ...(ns === null ? [] : [ns, ns.arrivalOverlay]),
      ...(config.swissGTFSRTToken === null ? [] : [new SwissRealtimeOverlay(config.swissGTFSRTToken)]),
      ...(config.tfNSWAPIToken === null ? [] : [new TfNSWRealtimeOverlay(config.tfNSWAPIToken)]),
      ...(vLine === null ? [] : [vLine]),
      ...(!config.pkpPLKEnabled || config.pkpPLKAPIKey === null
        ? []
        : [new PKPPLKRealtimeOverlay(config.pkpPLKAPIKey)]),
      ...(config.translinkNIApiToken !== null
        ? [new TranslinkNIOpendataOverlay(config.translinkNIApiToken)]
        : config.nirTigerAPIKey === null
          ? []
          : [new TranslinkNIRRealtimeOverlay(config.nirTigerAPIKey)]),
      ...(trafiklab === null ? [] : [trafiklab]),
      ...(config.trafiklabRealtimeAPIKey === null
        ? []
        : [new TrafiklabSwedenTimetableOverlay(config.trafiklabRealtimeAPIKey)]),
      ...(mobiliteitLu === null ? [] : [mobiliteitLu]),
      elron,
      irishRail,
    ], [
      new PieturasViviPositionOverlay(),
      ...(golemio === null ? [] : [golemio]),
      renfe,
      digitraffic,
      new EnturVehiclePositionOverlay(),
      ...(config.tfNSWAPIToken === null ? [] : [new TfNSWVehiclePositionOverlay(config.tfNSWAPIToken)]),
      new MalaysiaVehiclePositionOverlay(),
      new ViaRailVehiclePositionOverlay(),
      amtraker,
      elron,
      irishRail,
      ...(vLine === null ? [] : [vLine]),
      ...(trafiklab === null ? [] : [trafiklab]),
    ]),
  );
  const journeyProvider = new MainlineJourneyProvider(serbia, motis.journeys);
  const journeyService = config.journeyTokenSecret === null
    ? null
    : new JourneySearchService(
        journeyProvider,
        providers,
        config.journeyTokenSecret,
        journeyMetricLogger,
        undefined, undefined, { enabledSources: new Set([
          ...(golemio === null ? [] : ["golemio-pid"]),
          ...(trafiklab === null ? [] : ["trafiklab-national"]),
          ...(config.trafiklabRealtimeAPIKey === null ? [] : ["trafiklab-timetables"]),
          ...(dbTimetables.length === 0 ? [] : ["db-timetables"]),
          ...(config.swissGTFSRTToken === null ? [] : ["swiss"]),
          ...(config.tfNSWAPIToken === null ? [] : ["tfnsw"]),
          ...(ns === null ? [] : ["ns"]), ...(mobiliteitLu === null ? [] : ["mobiliteit"]),
          ...(config.pkpPLKEnabled && config.pkpPLKAPIKey !== null ? ["pkp-plk"] : []),
          ...(config.translinkNIApiToken || config.nirTigerAPIKey ? ["translink-ni"] : []),
        ]) },
      );
  const app = makeApp(
    repository,
    providers,
    config.logLevel,
    config.shareLinkSecret,
    journeyService,
    config.journeyTokenSecret,
  );
  const sender = config.apns.mode === "live"
    ? new LiveAPNsSender({
        teamId: config.apns.teamId,
        keyId: config.apns.keyId,
        topics: config.apns.topics,
        privateKey: config.apns.privateKey!,
      })
    : new DryRunPushSender((entry) => app.log.info(entry, "APNs dry run"));
  const watcher = new Watcher(repository, providers, sender, app.log);

  if (config.watcherEnabled) watcher.start();
  await app.listen({ host: "0.0.0.0", port: config.port });

  const shutdown = async (signal: string) => {
    app.log.info({ signal }, "shutting down");
    watcher.stop();
    await app.close();
    await pool.end();
  };
  process.once("SIGINT", () => void shutdown("SIGINT"));
  process.once("SIGTERM", () => void shutdown("SIGTERM"));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await start();
}

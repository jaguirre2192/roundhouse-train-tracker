import { DurableObject } from "cloudflare:workers";
import { ProviderRegistry } from "../providers/provider.js";
import { WatcherCycle, type WatcherTickReport } from "../worker/watcher-cycle.js";
import type { DeviceRegistration, SubscriptionInput } from "../worker/watcher-persistence.js";
import type { ObservationTrigger } from "../domain/platform-observation.js";
import type { CanonicalTripReference, TripSnapshot } from "../domain/snapshot.js";
import type {
  BoardEntrySnapshot,
  BoardReference,
  DiscoveryScope,
  StationSnapshot,
} from "../domain/discovery.js";
import type { WorkerEnv } from "./env.js";
import { SQLiteWatcherRepository, tripsPerTick } from "./sqlite-repository.js";
import { GmailInboxService } from "../gmail/gmail-service.js";
import type {
  GmailConnectResult,
  GmailConnectionSummary,
  GmailManualScanResult,
  GmailOAuthState,
  GmailTicketSummary,
} from "../gmail/gmail-models.js";
import { AuthService } from "../auth/auth-service.js";
import type { ForwardingService } from "../forwarding/forwarding-service.js";
import type {
  ForwardedTicketSummary,
  ForwardingAliasStatus,
  ParsedForwardedTicket,
} from "../forwarding/forwarding-models.js";
import type { AppUserSummary, GoogleAuthState, VerifiedIdentity } from "../auth/auth-models.js";
import { DarwinFTPFeed } from "./darwin-ftp.js";
import { createWatcherServices } from "./watcher-services.js";
import type { JourneySearchPageSnapshot, JourneySearchRequest, RailPlaceSnapshot } from "../domain/journey.js";
import type { JourneyPlanResolutionSnapshot, JourneySearchService } from "../services/journey-search-service.js";
import { JourneyServiceUnavailableError } from "./journey-validation.js";
import type { MutationContext, MutationDecision } from "./mutation-security.js";
import type { PlatformSamplingRunReport } from "../domain/platform-sampling.js";
import type { PlatformCorpusSampler } from "../services/platform-corpus-sampler.js";
import type { LiveActivityRegistration } from "../domain/live-activity.js";
import type { LiveActivityService } from "./live-activity-service.js";
import { PublicReadRateLimiter } from "../services/journey-rate-limiter.js";
import { GmailRetirement, type GmailRetirementReport } from "./gmail-retirement.js";
import { RailIndexStore } from "./rail-index-store.js";
import type { TrafiklabRegionalMaintainedOverlay } from "../providers/trafiklab-regional-maintained-overlay.js";
import { GTFSRailIndexStore } from "./mainline-gtfs-store.js";
import { gtfsRailCountries, type GTFSRailCountry } from "../providers/mainline-gtfs-index.js";
import { DenmarkSiriStore } from "./denmark-siri-store.js";
import { ingestDenmarkSiriPublication, ingestDenmarkSiriBatchPublication } from "./denmark-siri-publication.js";
import { withOptionalPlatformPersistence } from "./storage-availability.js";

import { ArrivalBoardService } from "./arrival-board-service.js";
import type { ArrivalBoardRequest } from "../domain/arrival-board.js";

const alarmIntervalMilliseconds = 20_000;

export class TrainTrackerWatcher extends DurableObject<WorkerEnv> {
  private readonly repository: SQLiteWatcherRepository;
  private readonly providers: ProviderRegistry;
  private readonly cycle: WatcherCycle;
  private readonly liveActivities: LiveActivityService;
  private readonly snapshotCache = new Map<string, { cachedAt: number; snapshot: TripSnapshot }>();
  private readonly snapshotRequests = new Map<string, Promise<TripSnapshot>>();
  private readonly discoveryCache = new Map<string, { cachedAt: number; stations: StationSnapshot[] }>();
  private readonly boardCache = new Map<string, { cachedAt: number; entries: BoardEntrySnapshot[] }>();
  // The singleton object sees every public read, so one in-memory limiter is global.
  private readonly arrivalBoards: ArrivalBoardService;
  private readonly publicReadLimiter = new PublicReadRateLimiter();
  private readonly gmail: GmailInboxService | null;
  private readonly auth: AuthService | null;
  private readonly forwarding: ForwardingService;
  private readonly darwin: DarwinFTPFeed | null;
  private readonly journey: JourneySearchService | null;
  private readonly platformSampler: PlatformCorpusSampler | null;
  private readonly gmailRetirement: GmailRetirement;
  private readonly trafiklabRegional: TrafiklabRegionalMaintainedOverlay | null;

  constructor(ctx: DurableObjectState, env: WorkerEnv) {
    super(ctx, env);
    const services = createWatcherServices(ctx, env);
    this.arrivalBoards = new ArrivalBoardService(ctx.storage.sql, (trip, key) => this.snapshot(trip, key));
    this.repository = services.repository;
    this.providers = services.providers;
    this.cycle = services.cycle;
    this.liveActivities = services.liveActivities;
    this.gmail = services.gmail;
    this.auth = services.auth;
    this.forwarding = services.forwarding;
    this.darwin = services.darwin;
    this.journey = services.journey;
    this.platformSampler = services.platformSampler;
    this.trafiklabRegional = services.trafiklabRegional;
    this.gmailRetirement = new GmailRetirement(services.storage, services.storage.sql, env.GMAIL_TOKEN_ENCRYPTION_KEY ?? null);
  }

  async health(): Promise<ReturnType<SQLiteWatcherRepository["health"]> & {
    gmailAccountsRemaining: number;
    alarmScheduledAt: string | null;
    platformSamplingEnabled: boolean;
    mainlineGTFS: Array<Awaited<ReturnType<GTFSRailIndexStore["health"]>>>;
    denmarkSiri: Awaited<ReturnType<DenmarkSiriStore["health"]>>;
    trafiklabRegional: ReturnType<TrafiklabRegionalMaintainedOverlay["health"]> | { configured: false };
    darwin: ReturnType<DarwinFTPFeed["status"]> | {
      configured: false;
      ready: false;
      compressedBytes: 0;
      messageFiles: 0;
      snapshotExpiresAt: null;
      listingExpiresAt: null;
    };
  }> {
    const alarm = await this.ctx.storage.getAlarm();
    return {
      ...this.repository.health(),
      gmailAccountsRemaining: this.gmailRetirement.remainingAccounts(),
      alarmScheduledAt: alarm === null ? null : new Date(alarm).toISOString(),
      platformSamplingEnabled: this.platformSampler !== null,
      mainlineGTFS: await Promise.all(gtfsRailCountries.map(country => new GTFSRailIndexStore(this.ctx.storage,country).health())),
      denmarkSiri: await new DenmarkSiriStore(this.ctx.storage).health(),
      trafiklabRegional: this.trafiklabRegional?.health() ?? { configured: false },
      darwin: this.darwin?.status() ?? {
        configured: false,
        ready: false,
        compressedBytes: 0,
        messageFiles: 0,
        snapshotExpiresAt: null,
        listingExpiresAt: null,
      },
    };
  }

  async registerDevice(input: DeviceRegistration, context: MutationContext): Promise<MutationDecision> {
    return this.repository.registerDevice(input, context);
  }

  async updateSkaneRailIndex(value: unknown): Promise<Awaited<ReturnType<RailIndexStore["save"]>>> {
    return new RailIndexStore(this.ctx.storage).save(value);
  }

  async updateMainlineGTFSIndex(country: GTFSRailCountry, value: unknown) {
    const result = await new GTFSRailIndexStore(this.ctx.storage,country).save(value);
    if (result.outcome === "stored") { this.discoveryCache.clear(); this.boardCache.clear(); this.snapshotCache.clear(); }
    return result;
  }

  async updateDenmarkSiri(xml: string) {
    const result = await ingestDenmarkSiriPublication(this.ctx.storage, xml);
    if (result.accepted && result.outcome === "stored") this.snapshotCache.clear();
    return result;
  }

  async updateDenmarkSiriBatch(xml: string[]) {
    const result = await ingestDenmarkSiriBatchPublication(this.ctx.storage, xml);
    if (result.accepted && result.outcome === "stored") this.snapshotCache.clear();
    return result;
  }

  async registerLiveActivity(input: LiveActivityRegistration, context: MutationContext): Promise<MutationDecision> {
    const decision = this.liveActivities.register(input, context);
    if (decision.allowed) await this.scheduleSoon();
    return decision;
  }

  async stopLiveActivity(installationId: string, activityId: string, context: MutationContext): Promise<MutationDecision> {
    const decision = this.liveActivities.stop(installationId, activityId, context);
    if (decision.allowed) await this.scheduleSoon();
    return decision;
  }

  async subscribe(input: SubscriptionInput, context: MutationContext): Promise<MutationDecision> {
    const decision = this.repository.subscribe(input, context);
    if (decision.allowed) await this.scheduleSoon();
    return decision;
  }

  async unsubscribe(
    installationId: string,
    tripId: string,
    context: MutationContext,
  ): Promise<MutationDecision> {
    return this.repository.unsubscribe(installationId, tripId, context);
  }

  async snapshot(reference: CanonicalTripReference, clientKey: string): Promise<TripSnapshot> {
    this.publicReadLimiter.consume("snapshot", clientKey);
    const key = `${reference.source}:${reference.nativeId}:${reference.serviceDate}`;
    const cached = this.snapshotCache.get(key);
    if (cached !== undefined && Date.now() - cached.cachedAt < 18_000) return cached.snapshot;
    const existing = this.snapshotRequests.get(key);
    if (existing !== undefined) return existing;

    const request = this.providers.fetchTrip(reference).then((snapshot) => {
      const forecasted = withOptionalPlatformPersistence(snapshot, () => {
        this.repository.recordPlatformObservations(snapshot, "snapshot");
        return this.repository.forecastPlatformSnapshot(snapshot, snapshot.fetchedAt);
      });
      if (this.snapshotCache.size >= 200) this.snapshotCache.clear();
      this.snapshotCache.set(key, { cachedAt: Date.now(), snapshot: forecasted });
      return forecasted;
    }).finally(() => this.snapshotRequests.delete(key));
    this.snapshotRequests.set(key, request);
    return request;
  }

  createArrivalBoard(input: ArrivalBoardRequest, clientKey: string) { return this.arrivalBoards.create(input, clientKey); }

  readArrivalBoard(token: string, clientKey: string) { return this.arrivalBoards.read(token, clientKey); }

  pruneArrivalBoards(): void { this.arrivalBoards.prune(); }

  recordPlatformSnapshot(snapshot: TripSnapshot, trigger: ObservationTrigger): number {
    return this.repository.recordPlatformObservations(snapshot, trigger);
  }

  forecastPlatformSnapshot(snapshot: TripSnapshot, generatedAt: string): TripSnapshot {
    return this.repository.forecastPlatformSnapshot(snapshot, generatedAt);
  }

  async searchStations(scope: DiscoveryScope, query: string, clientKey: string): Promise<StationSnapshot[]> {
    this.publicReadLimiter.consume("stations", clientKey);
    const key = `${scope}:${query.trim().toLowerCase()}`;
    const cached = this.discoveryCache.get(key);
    if (cached !== undefined && Date.now() - cached.cachedAt < 5 * 60_000) return cached.stations;
    const stations = await this.providers.searchStations(scope, query);
    if (this.discoveryCache.size >= 100) this.discoveryCache.clear();
    this.discoveryCache.set(key, { cachedAt: Date.now(), stations });
    return stations;
  }

  async board(reference: BoardReference, clientKey: string): Promise<BoardEntrySnapshot[]> {
    this.publicReadLimiter.consume("board", clientKey);
    const timeBucket = Math.floor(Date.parse(reference.at) / 15_000);
    const key = `${reference.source}:${reference.nativeId}:${reference.direction}:${timeBucket}`;
    const cached = this.boardCache.get(key);
    if (cached !== undefined && Date.now() - cached.cachedAt < 15_000) return cached.entries;
    const entries = await this.providers.fetchBoard(reference);
    if (this.boardCache.size >= 100) this.boardCache.clear();
    this.boardCache.set(key, { cachedAt: Date.now(), entries });
    return entries;
  }

  searchPlaces(query: string, limit: number, clientKey: string): Promise<RailPlaceSnapshot[]> {
    return this.requiredJourney().searchPlaces(query, limit, clientKey);
  }

  searchJourneys(input: JourneySearchRequest, clientKey: string): Promise<JourneySearchPageSnapshot> {
    return this.requiredJourney().searchJourneys(input, clientKey);
  }

  resolveJourneyPlan(tokens: string[], clientKey: string): Promise<JourneyPlanResolutionSnapshot> {
    return this.requiredJourney().resolvePlan(tokens, clientKey);
  }

  async runNow(): Promise<WatcherTickReport> {
    const [report] = await Promise.all([this.cycle.tick(), this.liveActivities.tick()]);
    this.repository.recordTick(report);
    return report;
  }

  async ensureScheduled(): Promise<void> {
    this.maintain();
    if (this.repository.hasWork() || this.liveActivities.hasWork()) {
      await this.scheduleSoon();
    } else {
      await this.parkAlarm();
    }
  }

  gmailAvailable(): boolean { return this.gmail !== null; }

  authAvailable(): boolean { return this.auth !== null; }

  createGoogleAuthState(
    stateHash: string,
    verifier: string,
    transactionId: string,
    appChallenge: string,
    expectedUserId: string | null,
    expiresAt: number,
  ): void {
    this.requiredAuth().createGoogleState(
      stateHash,
      verifier,
      transactionId,
      appChallenge,
      expectedUserId,
      expiresAt,
    );
  }

  consumeGoogleAuthState(stateHash: string): GoogleAuthState | null {
    return this.requiredAuth().consumeGoogleState(stateHash);
  }

  resolveAuthIdentity(
    identity: VerifiedIdentity,
    expectedUserId: string | null,
    appleRefreshToken: string | null,
  ): Promise<string | null> {
    return this.requiredAuth().resolveIdentity(identity, expectedUserId, appleRefreshToken);
  }

  createAuthExchangeCode(
    codeHash: string,
    userId: string,
    transactionId: string,
    appChallenge: string,
    expiresAt: number,
  ): void {
    this.requiredAuth().createExchangeCode(codeHash, userId, transactionId, appChallenge, expiresAt);
  }

  exchangeAuthSession(
    codeHash: string,
    transactionId: string,
    presentedChallenge: string,
    sessionHash: string,
    expiresAt: number,
  ): AppUserSummary | null {
    return this.requiredAuth().exchangeSession(
      codeHash,
      transactionId,
      presentedChallenge,
      sessionHash,
      expiresAt,
    );
  }

  createAuthSession(userId: string, sessionHash: string, expiresAt: number): AppUserSummary {
    return this.requiredAuth().createSession(userId, sessionHash, expiresAt);
  }

  authUserIdForSession(sessionHash: string): string | null {
    return this.requiredAuth().userIdForSession(sessionHash);
  }

  authUserForSession(sessionHash: string): AppUserSummary | null {
    return this.requiredAuth().userForSession(sessionHash);
  }

  revokeAuthSession(sessionHash: string): void {
    this.requiredAuth().revokeSession(sessionHash);
  }

  appleRefreshCredentials(userId: string) {
    return this.requiredAuth().appleRefreshCredentials(userId);
  }

  deleteAuthUser(userId: string): void {
    this.requiredAuth().deleteUser(userId);
  }

  createGmailOAuthState(
    stateHash: string,
    verifier: string,
    linkUserId: string,
    transactionId: string,
    appChallenge: string,
    expiresAt: number,
  ): boolean {
    return this.requiredGmail().createOAuthState(
      stateHash,
      verifier,
      linkUserId,
      transactionId,
      appChallenge,
      expiresAt,
    );
  }

  consumeGmailOAuthState(stateHash: string): GmailOAuthState | null {
    return this.requiredGmail().consumeOAuthState(stateHash);
  }

  gmailUserForSession(sessionHash: string): string | null {
    return this.requiredGmail().userIdForSession(sessionHash);
  }

  gmailUserForEmail(emailAddress: string): string | null {
    return this.requiredGmail().userIdForEmail(emailAddress);
  }

  connectGmailAccount(
    linkUserId: string,
    emailAddress: string,
    encryptedRefreshToken: string,
    historyId: string | null,
  ): GmailConnectResult {
    return this.requiredGmail().connectAccount(linkUserId, emailAddress, encryptedRefreshToken, historyId);
  }

  createGmailExchangeCode(
    codeHash: string,
    userId: string,
    transactionId: string,
    appChallenge: string,
    expiresAt: number,
  ): void {
    this.requiredGmail().createExchangeCode(
      codeHash,
      userId,
      transactionId,
      appChallenge,
      expiresAt,
    );
  }

  completeGmailConnection(
    codeHash: string,
    transactionId: string,
    presentedChallenge: string,
    authenticatedUserId: string,
  ): boolean {
    return this.requiredGmail().completeConnection(
      codeHash,
      transactionId,
      presentedChallenge,
      authenticatedUserId,
    );
  }

  exchangeGmailSession(codeHash: string, sessionHash: string, expiresAt: number): boolean {
    return this.requiredGmail().exchangeSession(codeHash, sessionHash, expiresAt);
  }

  gmailConnections(userId: string): GmailConnectionSummary[] {
    return this.requiredGmail().connections(userId);
  }

  gmailTickets(userId: string): GmailTicketSummary[] {
    return this.requiredGmail().tickets(userId);
  }

  scanGmailUser(userId: string): Promise<number> { return this.requiredGmail().scanUser(userId); }

  scanGmailUserManual(userId: string): Promise<GmailManualScanResult> {
    return this.requiredGmail().scanUserManual(userId);
  }

  scanGmailEmail(emailAddress: string): Promise<number> { return this.requiredGmail().scanEmail(emailAddress); }

  scanGmailDue(): Promise<number> { return this.gmail?.scanDue() ?? Promise.resolve(0); }

  /// Revokes and deletes stored Gmail import data; the cron runs it until none remains.
  retireGmailData(): Promise<GmailRetirementReport> { return this.gmailRetirement.run(); }

  async warmDarwin(): Promise<boolean> {
    if (this.darwin === null) return false;
    try {
      return await this.darwin.warm();
    } catch (error) {
      console.error("Darwin warmup failed", error);
      return false;
    }
  }

  samplePlatformCorpus(): Promise<PlatformSamplingRunReport | null> {
    return this.platformSampler?.run() ?? Promise.resolve(null);
  }

  gmailArtifact(userId: string, ticketId: string) {
    return this.requiredGmail().artifact(userId, ticketId);
  }

  disconnectGmailAccount(userId: string, accountId: string): void {
    this.requiredGmail().disconnectAccount(userId, accountId);
  }

  forwardingAliasStatus(userId: string): Promise<ForwardingAliasStatus> {
    return this.forwarding.aliasStatus(userId);
  }

  createForwardingAlias(userId: string): Promise<ForwardingAliasStatus> {
    return this.forwarding.createAlias(userId);
  }

  rotateForwardingAlias(userId: string): Promise<ForwardingAliasStatus> {
    return this.forwarding.rotateAlias(userId);
  }

  revokeForwardingAlias(userId: string): void {
    this.forwarding.revokeAlias(userId);
  }

  forwardingUserForTokenHash(tokenHash: string): string | null {
    return this.forwarding.userIdForTokenHash(tokenHash);
  }

  importForwardedTicket(userId: string, ticket: ParsedForwardedTicket, aliasHash?: string): Promise<boolean> {
    return this.forwarding.importTicket(userId, ticket, aliasHash);
  }

  forwardingTickets(userId: string): ForwardedTicketSummary[] {
    return this.forwarding.tickets(userId);
  }

  forwardingTicketArtifact(userId: string, ticketId: string) {
    return this.forwarding.artifact(userId, ticketId);
  }

  deleteForwardingTicket(userId: string, ticketId: string): boolean {
    return this.forwarding.deleteTicket(userId, ticketId);
  }

  async alarm(): Promise<void> {
    let scheduled = Date.now() + alarmIntervalMilliseconds;
    try {
      const report = await this.runNow();
      // A full batch means more trips are already due; drain them in fresh invocations.
      if (report.tripsClaimed >= tripsPerTick) scheduled = Date.now();
    } catch (error) {
      console.error("watcher alarm failed", error);
    }
    this.maintain();

    if (this.repository.hasWork() || this.liveActivities.hasWork()) {
      await this.ctx.storage.setAlarm(Math.max(scheduled, Date.now() + 1_000));
    } else {
      await this.parkAlarm();
    }
  }

  /// With nothing due now, sleep until the earliest future watch begins.
  private async parkAlarm(): Promise<void> {
    const nextWatchStart = this.repository.nextWatchStart();
    if (nextWatchStart === null) {
      await this.ctx.storage.deleteAlarm();
    } else {
      await this.ctx.storage.setAlarm(Math.max(nextWatchStart, Date.now() + 1_000));
    }
  }

  private maintain(): void {
    try {
      const report = this.repository.maintain();
      if (Object.values(report).some((count) => count > 0)) console.info("watcher_maintenance", report);
    } catch (error) {
      console.error("watcher maintenance failed", error);
    }
  }

  private async scheduleSoon(): Promise<void> {
    const now = Date.now();
    const target = now + 1_000;
    const existing = await this.ctx.storage.getAlarm();
    if (existing === null || existing <= now || existing > target) {
      await this.ctx.storage.setAlarm(target);
    }
  }

  private requiredGmail(): GmailInboxService {
    if (this.gmail === null) throw new Error("Gmail import is not configured");
    return this.gmail;
  }

  private requiredAuth(): AuthService {
    if (this.auth === null) throw new Error("Train Tracker accounts are not configured");
    return this.auth;
  }

  private requiredJourney(): JourneySearchService {
    if (this.journey === null) throw new JourneyServiceUnavailableError();
    return this.journey;
  }

}

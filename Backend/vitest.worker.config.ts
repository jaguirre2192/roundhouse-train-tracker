import { syntheticChepeSchedule } from "./tests/fixtures/chepe-sample.js";
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: "./wrangler.jsonc" },
    miniflare: { bindings: {
      APNS_MODE: "dry-run",
      CHEPE_TIMETABLE_JSON: syntheticChepeSchedule,
      // Local live-provider credentials must not enter deterministic fixtures.
      DB_TIMETABLES_CLIENT_ID: "",
      DB_TIMETABLES_API_KEY: "",
      NS_SUBSCRIPTION_KEY: "",
      SWISS_GTFS_RT_TOKEN: "",
      GOLEMIO_API_KEY: "",
      TRAFIKLAB_GTFS_SWEDEN_RT_API_KEY: "",
      TRAFIKLAB_GTFS_REGIONAL_RT_API_KEY: "",
      TRAFIKLAB_REALTIME_API_KEY: "",
      TFNSW_API_TOKEN: "",
      SHARE_LINK_SECRET: "worker-test-share-secret",
      JOURNEY_TOKEN_SECRET: "worker-test-journey-secret-32-characters",
      GMAIL_TOKEN_ENCRYPTION_KEY: "worker-test-token-encryption-key",
      TICKET_FORWARDING_SECRET: "worker-test-ticket-forwarding-secret-32c",
      TICKET_FORWARDING_DOMAIN: "gettraintracker.com",
    } },
  })],
  test: {
    include: ["worker-tests/**/*.test.ts"],
  },
});

import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: "./wrangler.rail-maintenance.jsonc" },
    miniflare: { bindings: {
      RAIL_DATA_REFRESH_SECRET: "rail-maintenance-test-secret-32-characters",
      TRAFIKLAB_GTFS_REGIONAL_STATIC_API_KEY: "rail-maintenance-static-test-key",
    } },
  })],
  test: { include: ["rail-maintenance-tests/**/*.test.ts"] },
});

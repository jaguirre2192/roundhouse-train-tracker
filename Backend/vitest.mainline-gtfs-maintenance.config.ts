import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";
export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.mainline-gtfs-maintenance.jsonc" },
    miniflare: { bindings: { RAIL_DATA_REFRESH_SECRET: "mainline-gtfs-test-refresh-secret-32-characters" } } })],
  test: { include: ["mainline-gtfs-maintenance-tests/**/*.test.ts"] },
});

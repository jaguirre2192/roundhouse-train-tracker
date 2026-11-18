import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";
export default defineConfig({
  resolve: { conditions: ["node"], alias: { kerberos: new URL("./src/providers/denmark-servicebus-no-kerberos.ts", import.meta.url).pathname } },
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.denmark-realtime.jsonc" },
    miniflare: { bindings: {
      RAIL_DATA_REFRESH_SECRET: "denmark-maintenance-test-secret-32-characters",
      DENMARK_SERVICEBUS_SUBSCRIPTION_URL: "amqps://sb-duvproddistribution.servicebus.windows.net/rail-main/test-main-office",
      DENMARK_SERVICEBUS_CLIENT_ID: "fixture-client-id",
      DENMARK_SERVICEBUS_CLIENT_SECRET: "fixture-client-secret",
      DENMARK_REGIONAL_WATCHDOG_URL: "",
    } },
  })],
  test: { include: ["denmark-realtime-tests/**/*.test.ts"] },
});

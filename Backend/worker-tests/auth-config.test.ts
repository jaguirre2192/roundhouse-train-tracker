import { describe, expect, it } from "vitest";
import { authEncryptionKey } from "../src/cloudflare/auth-config.js";
import type { WorkerEnv } from "../src/cloudflare/env.js";

describe("account auth encryption key selection", () => {
  it("prefers AUTH_TOKEN_ENCRYPTION_KEY when both are configured", () => {
    expect(authEncryptionKey({
      AUTH_TOKEN_ENCRYPTION_KEY: "auth-key",
      GMAIL_TOKEN_ENCRYPTION_KEY: "gmail-key",
    } as WorkerEnv)).toBe("auth-key");
  });

  it("falls back to GMAIL_TOKEN_ENCRYPTION_KEY for deployments that never set the new name", () => {
    expect(authEncryptionKey({ GMAIL_TOKEN_ENCRYPTION_KEY: "gmail-key" } as WorkerEnv)).toBe("gmail-key");
  });

  it("is undefined when neither key is configured", () => {
    expect(authEncryptionKey({} as WorkerEnv)).toBeUndefined();
  });
});

import { describe, expect, it } from "vitest";
import { googleAppCallbackURL } from "../src/cloudflare/auth-routes.js";

describe("account authentication callback", () => {
  it("returns Google authentication directly to the in-app session", () => {
    const callback = new URL(googleAppCallbackURL("exchange + code", "transaction/id"));

    expect(callback.protocol).toBe("traintracker:");
    expect(callback.hostname).toBe("auth-connected");
    expect(callback.searchParams.get("code")).toBe("exchange + code");
    expect(callback.searchParams.get("transaction")).toBe("transaction/id");
  });
});

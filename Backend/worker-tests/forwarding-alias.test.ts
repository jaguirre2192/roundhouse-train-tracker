import { env } from "cloudflare:test";
import { runInInitializedWatcher as runInDurableObject } from "./initialized-watcher.js";
import { describe, expect, it } from "vitest";
import { sha256 } from "../src/gmail/gmail-crypto.js";

async function seedUser(stub: ReturnType<typeof env.WATCHER.getByName>, userId: string): Promise<void> {
  await runInDurableObject(stub, (_instance, state) => {
    state.storage.sql.exec("INSERT OR IGNORE INTO gmail_users (id, created_at) VALUES (?, ?)", userId, Date.now());
  });
}

function localPart(address: string): string {
  return address.split("@")[0] ?? "";
}

function token(address: string): string {
  return localPart(address).replace(/^tickets\+/u, "");
}

describe("Forwarding alias lifecycle", () => {
  it("persists only a nonce and token hash, never the raw address, and resolves it back to the owner", async () => {
    const stub = env.WATCHER.getByName("alias-test-hash");
    await seedUser(stub, "user-hash");

    const created = await stub.createForwardingAlias("user-hash");
    expect(created.active).toBe(true);
    expect(created.address).toMatch(/^tickets\+[0-9a-f]{40}@gettraintracker\.com$/u);
    const createdToken = token(created.address ?? "");

    const rows = await runInDurableObject(stub, (_instance, state) => (
      state.storage.sql.exec<{ alias_nonce: string; token_hash: string }>(
        "SELECT alias_nonce, token_hash FROM forwarding_aliases WHERE user_id = ?",
        "user-hash",
      ).toArray()
    ));
    expect(rows).toHaveLength(1);
    expect(rows[0]?.token_hash).not.toBe(createdToken);
    expect(rows[0]?.token_hash).not.toContain(createdToken);
    expect(rows[0]?.alias_nonce).not.toBe(createdToken);
    expect(rows[0]?.alias_nonce).not.toContain(createdToken);
    expect(rows[0]?.token_hash).toBe(await sha256(createdToken));

    expect(await stub.forwardingUserForTokenHash(await sha256(createdToken))).toBe("user-hash");
  });

  it("re-derives the same address on every status read, simulating reinstall or a second device", async () => {
    const stub = env.WATCHER.getByName("alias-test-status");
    await seedUser(stub, "user-status");

    expect(await stub.forwardingAliasStatus("user-status")).toEqual({
      active: false, address: null, createdAt: null, rotatedAt: null,
    });

    const created = await stub.createForwardingAlias("user-status");
    expect(created.address).not.toBeNull();

    // Simulates the app reading status again after a reinstall or from a
    // second signed-in device: the address must reappear without the raw
    // token ever having been stored.
    const firstReRead = await stub.forwardingAliasStatus("user-status");
    const secondReRead = await stub.forwardingAliasStatus("user-status");
    expect(firstReRead.active).toBe(true);
    expect(firstReRead.address).toBe(created.address);
    expect(secondReRead.address).toBe(created.address);
    expect(firstReRead.createdAt).toBe(created.createdAt);
    expect(firstReRead.rotatedAt).toBe(created.rotatedAt);
  });

  it("create is idempotent once an alias exists and returns the same recomputed address", async () => {
    const stub = env.WATCHER.getByName("alias-test-idempotent");
    await seedUser(stub, "user-idempotent");

    const first = await stub.createForwardingAlias("user-idempotent");
    const second = await stub.createForwardingAlias("user-idempotent");
    expect(second.address).toBe(first.address);
    expect(second.createdAt).toBe(first.createdAt);
    expect(second.rotatedAt).toBe(first.rotatedAt);
  });

  it("rotation issues a fresh nonce and token, invalidates the old one, and preserves createdAt", async () => {
    const stub = env.WATCHER.getByName("alias-test-rotate");
    await seedUser(stub, "user-rotate");

    const created = await stub.createForwardingAlias("user-rotate");
    const oldToken = token(created.address ?? "");

    const rotated = await stub.rotateForwardingAlias("user-rotate");
    const newToken = token(rotated.address ?? "");

    expect(newToken).not.toBe(oldToken);
    expect(rotated.createdAt).toBe(created.createdAt);
    expect(await stub.forwardingUserForTokenHash(await sha256(oldToken))).toBeNull();
    expect(await stub.forwardingUserForTokenHash(await sha256(newToken))).toBe("user-rotate");

    // The rotated address must also be stable on subsequent reads, not just
    // the moment rotation returned it.
    const afterRotate = await stub.forwardingAliasStatus("user-rotate");
    expect(afterRotate.address).toBe(rotated.address);
  });

  it("revoke deletes the alias so inbound mail can no longer resolve it", async () => {
    const stub = env.WATCHER.getByName("alias-test-revoke");
    await seedUser(stub, "user-revoke");

    const created = await stub.createForwardingAlias("user-revoke");
    const revokedToken = token(created.address ?? "");
    await stub.revokeForwardingAlias("user-revoke");

    expect(await stub.forwardingUserForTokenHash(await sha256(revokedToken))).toBeNull();
    expect((await stub.forwardingAliasStatus("user-revoke")).active).toBe(false);
  });

  it("keeps aliases isolated between users", async () => {
    const stub = env.WATCHER.getByName("alias-test-isolation");
    await seedUser(stub, "user-a");
    await seedUser(stub, "user-b");

    const a = await stub.createForwardingAlias("user-a");
    const b = await stub.createForwardingAlias("user-b");
    expect(a.address).not.toBe(b.address);
    expect(await stub.forwardingUserForTokenHash(await sha256(token(a.address ?? "")))).toBe("user-a");
    expect(await stub.forwardingUserForTokenHash(await sha256(token(b.address ?? "")))).toBe("user-b");
  });
});

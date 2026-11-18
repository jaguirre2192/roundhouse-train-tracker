import type { WorkerEnv } from "./env.js";

export const defaultForwardingDomain = "gettraintracker.com";
const forwardingLocalPrefix = "tickets+";
const aliasTokenPattern = /^[0-9a-f]{40}$/u;

export class ForwardingServiceUnavailableError extends Error {
  constructor() {
    super("Ticket forwarding is unavailable");
    this.name = "ForwardingServiceUnavailableError";
  }
}

export function forwardingDomain(env: WorkerEnv): string {
  return env.TICKET_FORWARDING_DOMAIN ?? defaultForwardingDomain;
}

/** Throws ForwardingServiceUnavailableError rather than returning undefined so every caller fails the same clear way instead of re-deriving its own "is it configured" check. */
export function forwardingSecret(env: WorkerEnv): string {
  if (env.TICKET_FORWARDING_SECRET === undefined || env.TICKET_FORWARDING_SECRET.length < 32) {
    throw new ForwardingServiceUnavailableError();
  }
  return env.TICKET_FORWARDING_SECRET;
}

/**
 * Extracts the alias token from an envelope recipient, tolerating any
 * case-folding a relay may have applied. Requires the exact `tickets+`
 * subaddress prefix and the exact configured root domain, so only a
 * dedicated Email Routing rule for `tickets@<domain>` with subaddressing
 * enabled can deliver here — never a domain-wide catch-all. Returns null for
 * anything that is not a well-formed alias address, which the caller rejects
 * outright without ever attempting a storage lookup.
 */
export function parseAliasToken(to: string, domain: string): string | null {
  const at = to.lastIndexOf("@");
  if (at < 0) return null;
  const localPart = to.slice(0, at).toLowerCase();
  const recipientDomain = to.slice(at + 1).toLowerCase();
  if (recipientDomain !== domain.toLowerCase()) return null;
  if (!localPart.startsWith(forwardingLocalPrefix)) return null;
  const token = localPart.slice(forwardingLocalPrefix.length);
  return aliasTokenPattern.test(token) ? token : null;
}

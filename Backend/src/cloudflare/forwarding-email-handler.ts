import { base64URL, sha256 } from "../gmail/gmail-crypto.js";
import { parseForwardedTicket } from "../forwarding/forwarding-mime-parser.js";
import type { ParsedForwardedTicket } from "../forwarding/forwarding-models.js";
import { forwardingDomain, forwardingSecret, parseAliasToken } from "./forwarding-config.js";
import type { WorkerEnv } from "./env.js";

const maxInboundBytes = 10_000_000;

export function failsSenderAuthentication(headers: Headers): boolean {
  const results = headers.get("authentication-results");
  return results !== null && /\bdmarc=fail\b/iu.test(results);
}

async function sha256OfBytes(bytes: ArrayBuffer): Promise<string> {
  return base64URL(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)));
}

export async function handleForwardedEmail(
  message: ForwardableEmailMessage,
  env: WorkerEnv,
): Promise<void> {
  try {
    forwardingSecret(env);
  } catch {
    message.setReject("Forwarding is temporarily unavailable");
    return;
  }

  const token = parseAliasToken(message.to, forwardingDomain(env));
  if (token === null) {
    message.setReject("Unrecognized recipient");
    return;
  }
  if (message.rawSize > maxInboundBytes) {
    message.setReject("Message too large");
    return;
  }
  if (failsSenderAuthentication(message.headers)) {
    message.setReject("Message failed sender authentication");
    return;
  }

  const watcher = env.WATCHER.getByName("global");
  const tokenHash = await sha256(token);
  const userId = await watcher.forwardingUserForTokenHash(tokenHash);
  if (userId === null) {
    message.setReject("Unrecognized recipient");
    return;
  }

  let ticket: ParsedForwardedTicket | null;
  try {
    const raw = await new Response(message.raw).arrayBuffer();
    const messageIdHeader = message.headers.get("message-id");
    // Same-size messages without a Message-ID would otherwise collide on
    // `<token>:<rawSize>`; hashing the actual bytes (already buffered above,
    // so this never re-reads the stream) makes the key unique per message.
    const messageKey = messageIdHeader !== null
      ? await sha256(messageIdHeader)
      : await sha256OfBytes(raw);
    ticket = await parseForwardedTicket(raw, messageKey);
  } catch (error) {
    console.error("forwarded_email_import_failed", { reason: error instanceof Error ? error.name : "unknown" });
    return;
  }
  // Let the mail transport see a temporary storage failure. A successfully parsed ticket
  // must not be acknowledged as imported until the write has completed.
  if (ticket !== null && !await watcher.importForwardedTicket(userId, ticket, tokenHash)) {
    message.setReject("Unrecognized recipient");
  }
}

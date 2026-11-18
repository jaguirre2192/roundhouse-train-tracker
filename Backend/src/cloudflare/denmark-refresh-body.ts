import { denmarkOperation } from "../providers/denmark-servicebus-request.js";

/** Cloudflare may represent a network empty POST as a zero-byte stream. Check
 * actual bytes with a deadline; a declared zero length never bypasses the read. */
export async function emptyDenmarkRefreshBody(request: Request): Promise<boolean> {
  if (request.body === null) return true;
  const reader = request.body.getReader();
  const cancel = () => { void reader.cancel().catch(() => undefined); };
  try {
    return await denmarkOperation("publish", undefined, 2_000, async signal => {
      signal.addEventListener("abort", cancel, { once: true });
      try {
        if (Number(request.headers.get("content-length")) > 0) { cancel(); return false; }
        for (let chunks = 0; chunks < 16; chunks++) {
          const { value, done } = await reader.read();
          if (done) return true;
          if (value.byteLength > 0) { cancel(); return false; }
        }
        cancel(); return false;
      } finally { signal.removeEventListener("abort", cancel); }
    });
  } catch { cancel(); return false; }
  finally { try { reader.releaseLock(); } catch { /* Cancellation may still be settling. */ } }
}

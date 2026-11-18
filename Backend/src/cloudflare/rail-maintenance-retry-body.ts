const maximumRetryBodyBytes = 256;
const error = (value: string, status: number) => new Response(JSON.stringify({ error: value }), {
  status, headers: { "content-type": "application/json", "cache-control": "no-store" },
});

/** Call only after authenticating the operator. An empty POST is the normal daily run. */
export async function maintenanceRetryBody(request: Request): Promise<{ retryFailedAttemptAt?: string } | Response> {
  if (request.body === null) return {};
  if (Number(request.headers.get("content-length")) > maximumRetryBodyBytes) return error("too_large", 413);
  const reader = request.body.getReader(), chunks: Uint8Array[] = [];
  let length = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > maximumRetryBodyBytes) { await reader.cancel(); return error("too_large", 413); }
      chunks.push(value);
    }
    if (length === 0) return {};
    if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) return error("json_required", 415);
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    const body: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    if (typeof body !== "object" || body === null || Array.isArray(body)
      || Object.keys(body).length !== 1 || !("retryFailedAttemptAt" in body)) return error("invalid_retry", 400);
    const token = body.retryFailedAttemptAt;
    if (typeof token !== "string" || !Number.isFinite(Date.parse(token)) || new Date(token).toISOString() !== token) return error("invalid_retry", 400);
    return { retryFailedAttemptAt: token };
  } catch { return error("invalid_retry", 400); }
  finally { reader.releaseLock(); }
}

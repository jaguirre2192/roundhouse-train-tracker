import { RequestValidationError } from "./api-validation.js";

export class RequestBodyTooLargeError extends Error {
  constructor() {
    super("Request body is too large");
    this.name = "RequestBodyTooLargeError";
  }
}

export function json(value: unknown, status = 200, headers?: HeadersInit): Response {
  return Response.json(value, {
    status,
    headers: { ...Object.fromEntries(new Headers(headers)), "cache-control": "no-store" },
  });
}

/// Default ceiling for JSON request bodies; larger bodies are rejected with 413.
export const maximumJSONBodyBytes = 64 * 1_024;

export async function requestBody(request: Request, maximumBytes = maximumJSONBodyBytes): Promise<unknown> {
  return boundedJSONBody(request, maximumBytes);
}

export async function boundedJSONBody(request: Request, maximumBytes = 49_152): Promise<unknown> {
  const contentLength = request.headers.get("content-length");
  if (contentLength !== null && /^\d+$/u.test(contentLength.trim())
    && Number(contentLength) > maximumBytes) throw new RequestBodyTooLargeError();

  const body = await request.arrayBuffer();
  if (body.byteLength > maximumBytes) throw new RequestBodyTooLargeError();
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body)) as unknown;
  } catch {
    throw new RequestValidationError(["body must contain valid JSON"]);
  }
}

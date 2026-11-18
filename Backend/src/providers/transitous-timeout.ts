export const transitousRequestTimeoutMilliseconds = 20_000;

export function isTransitousTimeout(error: unknown, signal: AbortSignal): boolean {
  return signal.aborted || (error instanceof DOMException
    && (error.name === "AbortError" || error.name === "TimeoutError"));
}

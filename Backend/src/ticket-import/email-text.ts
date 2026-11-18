export function normalizeEmailText(raw: string): string {
  return raw
    .replace(/<style[\s\S]*?<\/style>/giu, " ")
    .replace(/<script[\s\S]*?<\/script>/giu, " ")
    .replace(/<br\s*\/?>|<\/(?:p|div|li|tr|td|h[1-6])>/giu, "\n")
    .replace(/<[^>]+>/gu, " ")
    .replace(/&nbsp;|&#160;/giu, " ")
    .replace(/&amp;/giu, "&")
    .replace(/&rarr;|&#8594;/giu, "→")
    .replace(/&ndash;|&#8211;/giu, "–")
    .replace(/&mdash;|&#8212;/giu, "—")
    .split(/\r?\n/gu)
    .map((line) => line.replace(/[\t ]+/gu, " ").trim())
    .filter(Boolean)
    .join("\n");
}

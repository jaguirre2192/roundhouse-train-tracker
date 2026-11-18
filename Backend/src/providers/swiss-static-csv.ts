/** Strict bounded GTFS CSV; labels retain spaces, accents and punctuation. */
export function swissCSV(bytes: Uint8Array, columns: readonly string[], consume: (row: Readonly<Record<string, string>>) => void): void {
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let pending = "", headers: string[] | null = null, rows = 0;
  const line = (value: string): void => {
    if (value === "") return;
    const fields: string[] = [];
    let field = "", quoted = false, closed = false;
    for (let i = 0; i < value.length; i += 1) {
      const char = value[i]!;
      if (quoted) {
        if (char === '"' && value[i + 1] === '"') { field += '"'; i += 1; }
        else if (char === '"') { quoted = false; closed = true; }
        else field += char;
      } else if (char === ",") { fields.push(field); field = ""; closed = false; }
      else if (char === '"' && field === "" && !closed) quoted = true;
      else if (char === '"' || closed) throw new Error("Invalid Swiss CSV quoting");
      else field += char;
    }
    if (quoted) throw new Error("Unclosed Swiss CSV quote");
    fields.push(field);
    if (headers === null) {
      headers = fields;
      if (new Set(headers).size !== headers.length || columns.some((column) => !headers!.includes(column))) {
        throw new Error("Invalid Swiss CSV columns");
      }
      return;
    }
    if (++rows > 150_000 || fields.length !== headers.length) throw new Error("Invalid Swiss CSV records");
    const row: Record<string, string> = {};
    columns.forEach((column) => { row[column] = fields[headers!.indexOf(column)]!; });
    consume(row);
  };
  for (let offset = 0; offset < bytes.length; offset += 16_384) {
    pending += decoder.decode(bytes.subarray(offset, offset + 16_384), { stream: true });
    let index: number;
    while ((index = pending.indexOf("\n")) >= 0) {
      if (index > 16_384) throw new Error("Oversized Swiss CSV record");
      line(pending.slice(0, index).replace(/\r$/u, "")); pending = pending.slice(index + 1);
    }
    if (pending.length > 16_384) throw new Error("Oversized Swiss CSV record");
  }
  pending += decoder.decode();
  if (pending) line(pending.replace(/\r$/u, ""));
  if (headers === null || rows === 0) throw new Error("Empty Swiss CSV");
}

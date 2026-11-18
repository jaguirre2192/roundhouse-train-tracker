/** Streaming CSV with selected columns, bounded records and quoted newlines. */
export function regionalCSV(columns: readonly string[], maximumRows: number, consume: (row: Readonly<Record<string, string>>) => void,
  acceptLine?: (line: string, headers: readonly string[]) => boolean): (data: Uint8Array, final: boolean) => void {
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let pending = "", record = "", quoted = false, rows = 0, headers: string[] | null = null, positions: number[] = [];
  function parse(line: string): string[] {
    if (!line.includes('"')) return line.split(",");
    const fields: string[] = []; let field = "", inside = false, closed = false;
    for (let i = 0; i < line.length; i += 1) {
      const char = line[i]!;
      if (inside) {
        if (char === '"' && line[i + 1] === '"') { field += '"'; i += 1; }
        else if (char === '"') { inside = false; closed = true; }
        else field += char;
      } else if (char === ",") { fields.push(field); field = ""; closed = false; }
      else if (char === '"' && field === "" && !closed) inside = true;
      else if (char === '"' || closed) throw new Error("Invalid regional CSV quoting");
      else field += char;
    }
    if (inside) throw new Error("Unclosed regional CSV quote");
    fields.push(field); return fields;
  }
  function line(value: string): void {
    record += value;
    if (record.length > 16_384) throw new Error("Oversized regional CSV record");
    // Escaped quote pairs do not change parity. State is only used to join lines;
    // the parser below independently validates where quotes can occur.
    if (value.includes('"')) for (const char of value) if (char === '"') quoted = !quoted;
    if (quoted) { record += "\n"; return; }
    const complete = record.replace(/\r$/u, ""); record = "";
    if (complete === "") return;
    if (headers !== null) {
      if (++rows > maximumRows) throw new Error("Excessive regional CSV records");
      if (acceptLine && !acceptLine(complete, headers)) return;
    }
    const fields = parse(complete);
    if (headers === null) {
      headers = fields.map((v) => v.replace(/^\uFEFF/u, ""));
      if (new Set(headers).size !== headers.length) throw new Error("Duplicate regional CSV header");
      positions = columns.map((name) => headers!.indexOf(name));
      return;
    }
    if (fields.length !== headers.length) throw new Error("Invalid regional CSV field count");
    const row: Record<string, string> = {};
    columns.forEach((name, i) => { row[name] = positions[i]! < 0 ? "" : fields[positions[i]!]!; });
    consume(row);
  }
  function text(value: string): void {
    pending += value;
    let newline: number;
    while ((newline = pending.indexOf("\n")) !== -1) {
      line(pending.slice(0, newline)); pending = pending.slice(newline + 1);
    }
    if (pending.length + record.length > 16_384) throw new Error("Oversized regional CSV record");
  }
  return (data, final) => {
    for (let i = 0; i < data.length; i += 16_384) text(decoder.decode(data.subarray(i, i + 16_384), { stream: true }));
    if (final) {
      text(decoder.decode()); if (pending) line(pending);
      if (quoted || record !== "" || headers === null) throw new Error("Incomplete regional CSV");
    }
  };
}

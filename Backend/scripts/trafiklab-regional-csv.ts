export function visitCSV(text: string, visit: (record: Readonly<Record<string, string>>) => void): void {
  let headers: string[] | null = null;
  let row: string[] = [];
  let field = "";
  let quoted = false;
  for (let index = 0; index <= text.length; index += 1) {
    const character = index === text.length ? "\n" : text[index]!;
    if (quoted) {
      if (character === '"' && text[index + 1] === '"') { field += '"'; index += 1; }
      else if (character === '"') quoted = false;
      else field += character;
    } else if (character === '"' && field.length === 0) quoted = true;
    else if (character === ",") { row.push(field); field = ""; }
    else if (character === "\n") {
      row.push(field.replace(/\r$/u, ""));
      if (row.some(Boolean)) {
        if (headers === null) headers = row.map((value) => value.replace(/^\uFEFF/u, ""));
        else visit(Object.fromEntries(headers.map((header, position) => [header, row[position] ?? ""])));
      }
      row = []; field = "";
    } else field += character;
  }
  if (quoted) throw new Error("Unclosed GTFS CSV field");
}

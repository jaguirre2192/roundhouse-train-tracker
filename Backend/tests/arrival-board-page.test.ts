import { runInNewContext } from "node:vm";
import { describe, expect, it } from "vitest";
import { arrivalBoardAsset } from "../src/cloudflare/arrival-board-page.js";

class Element extends EventTarget {
  textContent = "";
  hidden = false;
  disabled = false;
  dataset: Record<string, string> = {};
}

function board(station: string, note: string) {
  const next = new Date(Date.now() + 60 * 60_000).toISOString();
  return { station,note,service:"Regional",timeZone:"UTC",scheduled:next,time:next,basis:"scheduled",
    delayMinutes:null,checkedAt:new Date().toISOString(),reportedAt:null,updatesAvailable:true,expiresAt:next,credit:"" };
}
const flush = () => new Promise<void>(resolve => setImmediate(resolve));

describe("arrival board browser navigation", () => {
  it("clears an earlier recipient, suppresses out-of-order reads, and clears invalid or expired links", async () => {
    const elements = new Map<string, Element>();
    const get = (id: string) => {
      if (!elements.has(id)) elements.set(id, new Element());
      return elements.get(id)!;
    };
    const page = new EventTarget(), window = new EventTarget();
    const document = Object.assign(page, { hidden:false, getElementById:get });
    const pending: Array<{ token:string; reply:(r:Response) => void; signal:AbortSignal }> = [];
    const fetch = (_path: string, request: {body:string; signal:AbortSignal}) => new Promise<Response>(reply => {
      pending.push({token:(JSON.parse(request.body) as {token:string}).token, reply, signal:request.signal});
    });
    const location = { hash:"#"+ "a".repeat(43) };
    const swap = (token:string) => { location.hash = "#"+token; window.dispatchEvent(new Event("hashchange")); };
    const script = await arrivalBoardAsset("/meet/board.js")!.text();
    runInNewContext(script, { document, window, location, fetch, AbortController, Intl, Date, setTimeout:() => 1, clearTimeout:() => {} });

    pending[0]!.reply(Response.json(board("Stamford","First private note"))); await flush();
    expect(get("station").textContent).toBe("Stamford"); expect(get("note").textContent).toBe("First private note");
    get("refresh").dispatchEvent(new Event("click")); expect(pending).toHaveLength(2);
    swap("b".repeat(43));
    expect(get("station").textContent).toBe("Finding your train…"); expect(get("note").textContent).toBe("");
    expect(get("clock").textContent).toBe(""); expect(get("note-wrap").hidden).toBe(true);
    expect(pending[1]!.signal.aborted).toBe(true); expect(pending[2]!.token).toBe("b".repeat(43));
    const overnight = { ...board("Jacksonville", "Second private note"), basis:"estimated",
      scheduled:"2026-11-18T23:55:00Z", time:"2026-11-19T00:20:00Z", delayMinutes:25 };
    pending[2]!.reply(Response.json(overnight)); await flush();
    pending[1]!.reply(Response.json(board("Stamford","Late first note"))); await flush();
    expect(get("station").textContent).toBe("Jacksonville"); expect(get("note").textContent).toBe("Second private note");
    const scheduledDay = new Intl.DateTimeFormat(undefined, { month:"short", day:"numeric", timeZone:"UTC" }).format(new Date(overnight.scheduled));
    expect(get("calendar").textContent.split("Scheduled ")[1]).toContain(scheduledDay);
    get("refresh").dispatchEvent(new Event("click"));
    pending[3]!.reply(new Response(null, {status:503})); await flush();
    expect(get("basis").textContent).toBe("Last known estimate");
    expect(get("freshness").textContent).toContain("Updates paused");
    swap("invalid");
    expect(get("station").textContent).toBe("This arrival board has closed."); expect(get("note").textContent).toBe("");
    expect(pending).toHaveLength(4);
    swap("c".repeat(43));
    pending[4]!.reply(new Response(null, { status:410 })); await flush();
    expect(get("station").textContent).toBe("This arrival board has closed."); expect(get("note-wrap").hidden).toBe(true);
    swap("d".repeat(43));
    pending[5]!.reply(Response.json({ ...board("Stamford", ""), basis:"arrived" })); await flush();
    expect(get("basis").textContent).toBe("Arrival confirmed"); expect(get("refresh").hidden).toBe(true);
    page.dispatchEvent(new Event("visibilitychange")); expect(pending).toHaveLength(6);
  });
});

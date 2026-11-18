import { arrivalBoardStyles } from "./arrival-board-styles.js";

const privateHeaders = {
  "cache-control": "private, no-store", "referrer-policy": "no-referrer",
  "x-robots-tag": "noindex, nofollow, noarchive", "x-content-type-options": "nosniff",
  "content-security-policy": "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
};


const script = String.raw`
const get = id => document.getElementById(id);
let token = "", revision = 0, controller;
let pending = false, ended = false, timer, expireTimer, retryAt = 0, expiry = 0, lastChecked = "", lastBasis = "";
const formatter = (zone, options) => new Intl.DateTimeFormat(undefined, { ...options, timeZone: zone });
const finalArrival = () => lastBasis === "arrived" || lastBasis === "passed";
function message(title, detail) {
  get("station").textContent = title; get("service").textContent = detail;
  ["timing", "note-wrap", "credit", "freshness"].forEach(id => get(id).hidden = true);
  ["clock", "basis", "delay", "calendar", "note", "freshness", "credit"].forEach(id => get(id).textContent = "");
}
function expire() {
  ended = true; controller?.abort(); clearTimeout(timer); clearTimeout(expireTimer); get("refresh").hidden = true;
  message("This arrival board has closed.", "Ask the traveler for a new link if you still need to meet them.");
}
function render(board) {
  const zone = board.timeZone || "UTC";
  const clock = formatter(zone, { hour:"numeric", minute:"2-digit" });
  const day = formatter(zone, {weekday:"short", month:"short", day:"numeric"});
  const local = formatter(zone, { weekday:"short", month:"short", day:"numeric", hour:"numeric", minute:"2-digit", timeZoneName:"short" });
  const at = value => local.format(new Date(value));
  const dayAndZone = value => {
    const date = new Date(value);
    const zoneName = local.formatToParts(date).find(part => part.type === "timeZoneName")?.value || zone;
    return day.format(date) + " · " + zoneName;
  };
  get("station").textContent = board.station; get("service").textContent = board.service;
  get("timing").hidden = false; get("clock").textContent = board.time ? clock.format(new Date(board.time)) : "";
  const states = { arrived:"Arrival confirmed", passed:"Train reported past this stop", estimated:"Estimated arrival", scheduled:"Timetable arrival", cancelled:"This stop was cancelled", unavailable:"Arrival time unavailable" };
  lastBasis = board.basis; get("basis").textContent = states[board.basis];
  get("refresh").hidden = finalArrival();
  const d = board.delayMinutes;
  get("delay").textContent = d == null ? "" : d === 0 ? "On time" : Math.abs(d) + " min " + (d > 0 ? "late" : "early");
  get("delay").dataset.late = String(d > 0);
  const showSchedule = board.scheduled && board.time && new Date(board.time).getTime() !== new Date(board.scheduled).getTime() && ["estimated","arrived"].includes(board.basis);
  let schedule = "";
  if (showSchedule) {
    const scheduled = new Date(board.scheduled);
    const sameLocalDay = day.format(scheduled) === day.format(new Date(board.time));
    schedule = " · Scheduled " + (sameLocalDay ? clock.format(scheduled) : at(scheduled));
  }
  get("calendar").textContent = board.time ? dayAndZone(board.time) + schedule : "";
  get("note-wrap").hidden = !board.note; get("note").textContent = board.note || "";
  get("credit").hidden = !board.credit;
  if (board.credit === "Amtraker") {
    const source = document.createElement("a");
    source.href = "https://amtraker.com"; source.rel = "noreferrer"; source.target = "_blank"; source.textContent = "Amtraker";
    get("credit").replaceChildren(document.createTextNode("Amtrak data from "), source);
  } else { get("credit").textContent = board.credit ? "Train data from " + board.credit : ""; }
  get("freshness").hidden = false;
  get("freshness").textContent = board.reportedAt ? "Reported " + at(board.reportedAt)
    : !board.updatesAvailable ? (board.scheduled ? "Live updates unavailable. Showing the saved timetable." : "Live updates unavailable.")
    : board.checkedAt ? "Checked " + at(board.checkedAt) : "No recent update.";
  lastChecked = board.checkedAt ? at(board.checkedAt) : "";
  clearTimeout(expireTimer);
  expiry = new Date(board.expiresAt).getTime();
  const until = expiry - Date.now();
  if (until <= 0) { expire(); return; }
  const rendered = revision;
  if (until < 2_000_000_000) expireTimer = setTimeout(() => { if (rendered === revision) expire(); }, until);
}
function schedule() {
  clearTimeout(timer);
  if (!ended && !finalArrival() && !document.hidden) timer = setTimeout(refresh, Math.max(60_000, retryAt - Date.now()));
}
async function refresh() {
  if (pending || ended || document.hidden) return;
  if (expiry && expiry <= Date.now()) { expire(); return; }
  if (finalArrival()) return;
  if (Date.now() < retryAt) { schedule(); return; }
  const requested = revision;
  controller = new AbortController();
  pending = true; get("refresh").disabled = true;
  try {
    const res = await fetch("/v1/arrival-boards/status", { method:"POST", credentials:"omit", cache:"no-store", signal:controller.signal,
      headers:{ "content-type":"application/json" }, body:JSON.stringify({token}) });
    if (requested !== revision || ended) return;
    if ([404,410].includes(res.status)) { expire(); return; }
    if (!res.ok) { const seconds = Number(res.headers.get("retry-after")); if (seconds > 0) retryAt = Date.now() + seconds * 1000; throw Error(); }
    const board = await res.json();
    if (requested === revision && !ended) render(board);
  } catch {
    if (requested !== revision || ended) return;
    if (lastBasis === "estimated") get("basis").textContent = "Last known estimate";
    get("freshness").hidden = false; get("freshness").textContent = lastChecked ? "Updates paused. Last checked " + lastChecked : "Updates paused. Trying again shortly.";
    if (get("timing").hidden) { get("station").textContent = "Waiting for an update"; get("service").textContent = "Your arrival board will appear here."; }
  } finally { if (requested === revision) { pending = false; get("refresh").disabled = false; schedule(); } }
}
get("refresh").addEventListener("click", refresh);
document.addEventListener("visibilitychange", () => { clearTimeout(timer); if (!document.hidden) refresh(); });
function openLink() {
  const next = location.hash.slice(1);
  if (revision && token === next) return;
  revision++; token = next; controller?.abort(); clearTimeout(timer); clearTimeout(expireTimer);
  pending = false; ended = false; retryAt = 0; expiry = 0; lastChecked = ""; lastBasis = "";
  get("refresh").hidden = false; get("refresh").disabled = false;
  message("Finding your train…", "");
  if (/^[A-Za-z0-9_-]{43}$/.test(token)) { refresh(); } else { expire(); }
}
window.addEventListener("hashchange", openLink);
window.addEventListener("pageshow", event => {
  if (location.hash.slice(1) !== token) openLink();
  else if (expiry && expiry <= Date.now()) expire();
  else if (event.persisted) refresh();
});
openLink();
`;

export function arrivalBoardAsset(path: string): Response | null {
  const html = path === "/meet";
  if (!html && path !== "/meet/board.js" && path !== "/meet/board.css") return null;
  const body = html ? `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Meet my train · Roundhouse</title><link rel="icon" href="data:,"><link rel="stylesheet" href="/meet/board.css"><script src="/meet/board.js" defer></script></head>
<body><main><header><span class="brand" role="img" aria-label="Roundhouse">Roundhouse</span><span class="page-title">Meet my train</span></header>
<article><div class="panel"><h1 id="station">Finding your train…</h1><div class="service" id="service"></div>
<div id="timing" hidden><div class="clock" id="clock"></div><p id="basis"></p><p id="delay"></p><p id="calendar"></p></div></div>
<div id="note-wrap" class="panel" hidden><h2 class="note-title">Where to meet</h2><p id="note" dir="auto"></p></div></article>
<div class="foot"><p id="freshness" role="status"></p><button id="refresh" type="button">Refresh</button></div><p id="credit" hidden></p>
<noscript>Turn on JavaScript to open this private arrival board and receive updates.</noscript></main></body></html>` : path.endsWith(".js") ? script : arrivalBoardStyles;
  return new Response(body, { headers: { ...privateHeaders, "content-type":
    (html ? "text/html" : path.endsWith(".js") ? "text/javascript" : "text/css") + "; charset=utf-8" } });
}

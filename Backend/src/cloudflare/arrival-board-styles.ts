import { wordmark } from "./arrival-board-wordmark.js";

export const arrivalBoardStyles = `
:root {
  color-scheme: light dark;
  --paper:#f7f5ef;
  --card:#fffdf8;
  --ink:#123e49;
  --muted:#4d646b;
  --rule:#ccd6d5;
  --accent:#22656d;
  --late:#914403;
}
@media (prefers-color-scheme: dark) {
  :root {
    --paper:#1c2429;
    --card:#242f34;
    --ink:#f6f3df;
    --muted:#b2c4c7;
    --rule:#405259;
    --accent:#9cd3d6;
    --late:#ffba72;
  }
}
* {
  box-sizing: border-box;
}
[hidden] {
  display: none !important;
}
html,
body {
  margin: 0;
  min-height: 100%;
}
body {
  font:
    1rem/1.45 -apple-system,
    BlinkMacSystemFont,
    "Segoe UI",
    sans-serif;
  color: var(--ink);
  background: var(--paper);
}
main {
  max-width: 38rem;
  margin: clamp(2rem, 8vh, 6rem) auto;
  padding: 0 clamp(1rem, 4vw, 1.75rem);
}
header,
.foot {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: .85rem;
  flex-wrap: wrap;
}
header {
  padding-bottom: 1rem;
  align-items: center;
}
.brand {
  display: block;
  width: 8.8rem;
  aspect-ratio: 6.4;
  background: currentColor;
  font-size: 0;
  -webkit-mask: url("${wordmark}") center/cover no-repeat;
  mask: url("${wordmark}") center/cover no-repeat;
}
.page-title,
.note-title {
  color: var(--muted);
  font-size: .94rem;
  font-weight: 600;
}
.note-title {
  margin: 0;
}
article {
  background: var(--card);
  border: 1px solid var(--rule);
  border-radius: 1rem;
  overflow: hidden;
}
.panel {
  padding: clamp(1.35rem, 5vw, 2.2rem);
}
h1 {
  font-size: clamp(2rem, 6.7vw, 3.15rem);
  letter-spacing: -.03em;
  line-height: 1.06;
  margin: 0 0 .45rem;
  overflow-wrap: anywhere;
}
.service {
  color: var(--muted);
}
.clock {
  margin-top: 2.35rem;
  line-height: 1.04;
  font-size: clamp(3.65rem, 13vw, 6rem);
  letter-spacing: -.04em;
  font-weight: 650;
  font-variant-numeric: tabular-nums;
}
#basis {
  margin: .4rem 0 0;
  color: var(--accent);
  font-weight: 600;
}
#delay {
  margin: .2rem 0 0;
  font-weight: 650;
}
#delay[data-late=true] {
  color: var(--late);
}
#calendar {
  font-size: .92rem;
  color: var(--muted);
  margin: .65rem 0 0;
}
#note-wrap {
  border-top: 1px dashed var(--rule);
  padding-top: 1.1rem;
  padding-bottom: 1.3rem;
}
#note {
  margin: .4rem 0 0;
  overflow-wrap: anywhere;
  white-space: pre-wrap;
}
.foot,
#credit {
  font-size: .86rem;
  color: var(--muted);
  margin: 1rem .2rem;
}
#freshness {
  margin: 0;
}
a,
button {
  color: var(--accent);
}
button {
  background: transparent;
  font: inherit;
  font-weight: 600;
  border: 1px solid var(--rule);
  border-radius: 1rem;
  padding: .6rem .95rem;
  cursor: pointer;
}
button:disabled {
  opacity: .6;
}
a {
  font-weight: 550;
}
::selection {
  background: var(--ink);
  color: var(--paper);
}
:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 3px;
}
a {
  text-underline-offset: .18em;
}
`;

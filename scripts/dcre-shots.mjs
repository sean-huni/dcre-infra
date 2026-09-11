// Capture every DCRE dashboard. Traps guarded against, both from this estate's own experience:
//  1. Grafana lazy-renders panels: a panel paints only once it intersects the viewport, so a
//     normal viewport plus fullPage expands the image WITHOUT scrolling panels in, and they
//     photograph empty. Use a viewport taller than the board.
//  2. Assert the EFFECT: count POST /api/ds/query requests and their failures, so a board that
//     rendered nothing is distinguishable from a board that rendered zeros.
import { chromium } from 'playwright';
import fs from 'node:fs';
const G = process.env.DCRE_GRAFANA_URL ?? 'http://localhost:3001';
const OUT = process.env.SHOT_DIR ?? '/tmp/dcre-shots';
const TAG = process.env.SHOT_TAG ?? 'run';
fs.mkdirSync(OUT, { recursive: true });
const boards = [
  ['dcre-fleet-overview', 'DCRE Fleet Overview'],
  ['dcre-stage-jobs',     'DCRE Stage Jobs'],
  ['dcre-traces',         'DCRE Traces'],
  ['dcre-logs',           'DCRE Logs'],
];
const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 1920, height: 4200 }, deviceScaleFactor: 1 });
const p = await ctx.newPage();
await p.goto(`${G}/login`, { waitUntil: 'domcontentloaded' });
try {
  await p.fill('input[name="user"]', 'admin'); await p.fill('input[name="password"]', 'admin');
  await p.click('button[type="submit"]'); await p.waitForTimeout(3000);
} catch {}
const rows = [];
for (const [uid, title] of boards) {
  let q = 0, qf = 0;
  const onReq = r => { if (r.url().includes('/api/ds/query')) q++; };
  const onRes = r => { if (r.url().includes('/api/ds/query') && r.status() >= 400) qf++; };
  p.on('request', onReq); p.on('response', onRes);
  await p.goto(`${G}/d/${uid}?from=now-30m&to=now&kiosk`, { waitUntil: 'networkidle' });
  await p.waitForTimeout(9000);
  const file = `${OUT}/${TAG}-${uid}.png`;
  await p.screenshot({ path: file });
  const noData = await p.locator('text=/No data/i').count();
  const panels = await p.locator('[data-testid^="data-testid Panel header"]').count();
  rows.push({ uid, title, bytes: fs.statSync(file).size, panels, noData, dsQueries: q, dsFailures: qf });
  p.off('request', onReq); p.off('response', onRes);
}
console.log(JSON.stringify(rows, null, 2));
await b.close();

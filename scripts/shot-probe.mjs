// Baseline capture probe: proves login, render and save work BEFORE the real dashboards exist.
// Trap this guards against, from the estate's own script: Grafana lazy-renders panels, so a
// normal viewport plus fullPage expands the image without scrolling panels into view and they
// photograph empty. Use a viewport taller than the board.
import { chromium } from 'playwright';
const G = process.env.DCRE_GRAFANA_URL ?? 'http://localhost:3001';
const OUT = process.env.SHOT_DIR ?? '/tmp/dcre-shots';
const fs = await import('node:fs');
fs.mkdirSync(OUT, { recursive: true });
const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 1600, height: 3200 }, deviceScaleFactor: 1 });
const p = await ctx.newPage();
const fails = [];
p.on('response', r => { if (r.url().includes('/api/ds/query') && r.status() >= 400) fails.push(r.status()); });
let dsQueries = 0;
p.on('request', r => { if (r.url().includes('/api/ds/query')) dsQueries++; });
await p.goto(`${G}/login`, { waitUntil: 'domcontentloaded' });
try {
  await p.fill('input[name="user"]', 'admin');
  await p.fill('input[name="password"]', 'admin');
  await p.click('button[type="submit"]');
  await p.waitForTimeout(3000);
} catch { /* may already be signed in */ }
await p.goto(`${G}/dashboards`, { waitUntil: 'networkidle' });
await p.waitForTimeout(2500);
const title = await p.title();
await p.screenshot({ path: `${OUT}/00-probe-dashboard-list.png` });
const st = fs.statSync(`${OUT}/00-probe-dashboard-list.png`);
console.log(JSON.stringify({ grafana: G, title, bytes: st.size, dsQueries, dsFailures: fails.length }, null, 2));
await b.close();

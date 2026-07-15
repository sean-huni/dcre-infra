// Screenshot every dcre dashboard as every org user (isolation + rendering evidence).
// Spec M8 client-stats Task 15 (spec gates 4-5). Headless chromium kiosk shots.
//
// Run:
//   npm install playwright            # (or have playwright resolvable on NODE path)
//   npx -y playwright@latest install chromium
//   node scripts/grafana-screenshots.mjs
//
// Target the IN-CLUSTER LGTM Grafana on host :3001 (scripts/lgtm-forward.sh forwards
// svc/lgtm 3000 -> host 3001). We deliberately read DCRE_GRAFANA_URL, NOT the ambient
// GRAFANA_URL: that env var points the Grafana MCP at the *compose* LGTM on :3000 (a
// different Grafana, also healthy), and capturing it would be wrong evidence. Same
// convention as scripts/grafana-dashboards.sh and scripts/grafana-provision.sh (Task 12).
//
// Login password is `devdev`: Grafana 13 enforces a min password length that rejected the
// original `dev` (Task 12). Each user (fnbcc01/fnbcc02/fnbrf01/fnbinternal) lands in its OWN
// org (Main-Org membership was removed in Task 12), so the client pack renders that org's
// client-scoped data only - which is exactly the per-client isolation this evidence proves.
//
// TALL VIEWPORT (critical): Grafana's dashboard scene lazy-renders panels - a panel paints
// its data only once it intersects the viewport. A normal-height viewport + a fullPage
// screenshot expands the capture height WITHOUT scrolling each panel into view, so panels
// below the first screenful stay blank (queries succeed, bodies never paint). We size the
// viewport taller than the tallest dashboard (the 15-panel client pack) so every panel is
// in view at load and renders, then clip the shot to the real content height.
import { chromium } from 'playwright';

const G = process.env.DCRE_GRAFANA_URL ?? 'http://localhost:3001';
const OUT = process.env.OUT_DIR ?? 'build/screenshots';
const PASSWORD = process.env.GRAFANA_PASSWORD ?? 'devdev';
const VIEWPORT = { width: 1920, height: 3600 };
const targets = [
  { user: 'fnbcc01', dash: 'dcre-client-stats' },
  { user: 'fnbcc02', dash: 'dcre-client-stats' },
  { user: 'fnbrf01', dash: 'dcre-client-stats' },
  { user: 'fnbinternal', dash: 'dcre-client-stats' },
  { user: 'fnbinternal', dash: 'dcre-internal-stats' },
];

const browser = await chromium.launch();
for (const t of targets) {
  // Fresh context per user so each session cookie is isolated (no org bleed between shots).
  const ctx = await browser.newContext({ viewport: VIEWPORT });
  const page = await ctx.newPage();

  await page.goto(`${G}/login`, { waitUntil: 'networkidle' });
  // Grafana 13 login is a React SPA: wait for the fields to render, then fill by name.
  await page.waitForSelector('input[name="user"]', { timeout: 15000 });
  await page.fill('input[name="user"]', t.user);
  await page.fill('input[name="password"]', PASSWORD);
  await page.click('button[type="submit"]');
  // Wait until we are OFF the login route. A function predicate is correct here; the naive
  // regex /(?!.*login)/ test-matches even while still on /login and would race the redirect.
  await page.waitForURL((u) => !u.pathname.includes('/login'), { timeout: 15000 });

  await page.goto(`${G}/d/${t.dash}?kiosk&from=now-30d&to=now`, { waitUntil: 'networkidle' });
  // Wait for every panel query to stop loading (capped), then a buffer for the final paint.
  await page
    .waitForFunction(
      () => document.querySelectorAll('[aria-label="Panel loading bar"]').length === 0,
      { timeout: 30000 },
    )
    .catch(() => {});
  await page.waitForTimeout(10000);

  // Clip to the real content height (bottom of the lowest panel) so short dashboards do not
  // carry a tall band of empty viewport below the panels.
  const height = await page.evaluate(() => {
    const panels = [...document.querySelectorAll('[data-viz-panel-key]')];
    if (!panels.length) return document.body.scrollHeight;
    return Math.ceil(Math.max(...panels.map((p) => p.getBoundingClientRect().bottom))) + 16;
  });
  await page.screenshot({
    path: `${OUT}/${t.user}-${t.dash}.png`,
    clip: { x: 0, y: 0, width: VIEWPORT.width, height: Math.min(height, VIEWPORT.height) },
  });
  console.log(`captured ${t.user}-${t.dash}.png`);
  await ctx.close();
}
await browser.close();

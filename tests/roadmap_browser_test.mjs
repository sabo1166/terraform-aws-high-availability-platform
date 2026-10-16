// Browser test for docs/roadmap/index.html, run in a real Chromium-family browser.
// Optional local check (not part of CI): it needs a browser and puppeteer-core, neither of which the repo vendors.
//
//   PUPPETEER_DIR=<folder containing node_modules/puppeteer-core> \
//   CHROME=<path to chrome or msedge> \
//   node tests/roadmap_browser_test.mjs [--shots <output dir>]
//
// The page is loaded from file:// and every network request other than file:// is a test failure.
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const require = createRequire(path.join(process.env.PUPPETEER_DIR ?? '.', 'x.js'));
const puppeteer = require('puppeteer-core');
const here = path.dirname(fileURLToPath(import.meta.url));
const url = pathToFileURL(process.env.PAGE ?? path.join(here, '..', 'docs', 'roadmap', 'index.html')).href;   // PAGE: test another copy (used for mutation tests)
const shotsDir = process.argv.includes('--shots') ? process.argv[process.argv.indexOf('--shots') + 1] : null;

let passed = 0;
const failures = [];
const ok = (cond, msg) => { if (cond) passed++; else failures.push(msg); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(page, fn, timeout = 30000, arg) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeout) { if (await page.evaluate(fn, arg)) return true; await sleep(40); }
  return false;
}

const browser = await puppeteer.launch({ executablePath: process.env.CHROME, headless: 'new', args: ['--no-sandbox', '--allow-file-access-from-files'] });
async function open(opts = {}) {
  const page = await browser.newPage();
  const problems = { console: [], external: [], page: [] };
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) problems.console.push(m.text()); });
  page.on('pageerror', (e) => problems.page.push(String(e)));
  page.on('request', (r) => { if (!r.url().startsWith('file://') && !r.url().startsWith('data:')) problems.external.push(r.url()); });
  await page.setViewport(opts.viewport ?? { width: 1440, height: 900 });
  if (opts.reduced) await page.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }]);
  await page.goto(url, { waitUntil: 'load' });
  return { page, problems };
}
const state = (page) => page.evaluate(() => window.RM_SIM.state());

/* ------------------------------------------------------------------ 1. structure, data, no network */
{
  const { page, problems } = await open();
  ok(problems.page.length === 0, `page errors: ${problems.page.join(' | ')}`);
  ok(problems.console.length === 0, `console errors/warnings: ${problems.console.join(' | ')}`);
  ok(problems.external.length === 0, `external requests were made: ${problems.external.join(', ')}`);

  const order = await page.evaluate(() => {
    const r = document.querySelector('#roadmap'), a = document.querySelector('#architecture');
    return { roadmapFirst: !!(r.compareDocumentPosition(a) & Node.DOCUMENT_POSITION_FOLLOWING), stages: document.querySelectorAll('.stage').length,
      counts: [...document.querySelectorAll('#counts dd')].map((d) => d.textContent), lang: document.documentElement.lang,
      h1: document.querySelectorAll('h1').length, svgNodes: document.querySelectorAll('#diagram svg.arch .node').length };
  });
  ok(order.roadmapFirst, 'the roadmap section must come before the architecture section');
  ok(order.stages === 12, `expected 12 stages, got ${order.stages}`);
  ok(JSON.stringify(order.counts) === JSON.stringify(['9 of 12', '2', '1', '0 of 12']), `unexpected status counts ${order.counts}`);
  ok(order.lang === 'en' && order.h1 === 1, 'html lang and a single h1');
  ok(order.svgNodes >= 20, `diagram nodes missing (${order.svgNodes})`);
  const nameless = await page.evaluate(() => [...document.querySelectorAll('button')].filter((b) => !(b.textContent.trim() || b.getAttribute('aria-label'))).length);
  ok(nameless === 0, `${nameless} buttons have no accessible name`);
  ok(await page.evaluate(() => !!document.querySelector('#step-live[aria-live="polite"]')), 'live region for step announcements');

  /* roadmap interactions */
  const t = await page.$('#toggle-foundation');
  await t.click();
  ok(await page.evaluate(() => document.querySelector('#toggle-foundation').getAttribute('aria-expanded') === 'true' && !document.querySelector('#panel-foundation').hidden), 'stage opens on click');
  await t.click();
  ok(await page.evaluate(() => document.querySelector('#panel-foundation').hidden), 'stage closes on second click');
  await page.focus('#toggle-design');
  await page.keyboard.press('ArrowDown');
  ok(await page.evaluate(() => document.activeElement.id === 'toggle-foundation'), 'ArrowDown moves focus to the next stage');
  await page.click('.filters [data-filter="planned"]');
  ok(await page.evaluate(() => [...document.querySelectorAll('.stage')].filter((s) => !s.hidden).length === 1), 'planned filter shows exactly one stage');
  await page.click('.filters [data-filter="aws-pending"]');
  ok(await page.evaluate(() => [...document.querySelectorAll('.stage')].filter((s) => !s.hidden).length === 11), 'AWS-pending filter shows 11 stages');
  await page.click('.filters [data-filter="all"]');
  await page.click('#expand-all');
  ok(await page.evaluate(() => [...document.querySelectorAll('.panel')].every((p) => !p.hidden)), 'expand all opens every panel');
  const links = await page.evaluate(() => [...document.querySelectorAll('.panel .files a, .refs a, #facts-grid a')].map((a) => a.getAttribute('href')));
  ok(links.length > 20 && links.every((h) => h.startsWith('../../')), 'file links are relative to the repository root');
  await page.focus('#btn-play');
  await page.keyboard.press('Shift');   // keyboard modality, so :focus-visible applies
  const focusStyle = await page.evaluate(() => getComputedStyle(document.querySelector('#btn-play')).outlineStyle);
  ok(focusStyle !== 'none', 'focused controls show an outline');
  if (shotsDir) { await page.evaluate(() => { document.querySelector('#expand-all').click(); window.scrollTo(0, 0); }); await page.screenshot({ path: path.join(shotsDir, 'desktop-top.png') }); }
  await page.close();
}

/* ------------------------------------------------------------------ 2. simulator behavior */
{
  const { page, problems } = await open();
  await page.evaluate(() => document.querySelector('#architecture').scrollIntoView());

  // Sample which main-path connections are lit (what a viewer sees) and record where each packet starts.
  await page.evaluate(() => {
    window.__log = { live: [], starts: [] };
    const svg = document.querySelector('#diagram svg.arch');
    let prev = new Set();
    setInterval(() => {
      const now = new Set([...svg.querySelectorAll('.edge.is-live')].map((e) => e.id).filter((id) => !id.startsWith('hc_') && id !== 'e_repl'));
      now.forEach((id) => { if (!prev.has(id)) window.__log.live.push(id); });
      prev = now;
    }, 15);
    new MutationObserver((muts) => {
      for (const m of muts) m.addedNodes.forEach((n) => { if (n.nodeType === 1 && n.classList && n.classList.contains('packet')) window.__log.starts.push({ rev: n.classList.contains('rev'), t: n.getAttribute('transform') }); });
    }).observe(svg.querySelector('#packet-layer'), { childList: true });
  });

  let s = await state(page);
  ok(s.idx === -1 && s.phase === 'idle' && !s.playing, `initial state ${JSON.stringify(s)}`);
  ok(await page.evaluate(() => document.querySelector('#sim-badge').textContent.includes('not live AWS telemetry')), 'simulation is labelled as not live telemetry');

  // step forward from idle: runs exactly one step, then waits
  await page.click('#btn-step');
  s = await state(page);
  ok(s.idx === 0 && s.phase === 'moving' && !s.playing, `after Step: ${JSON.stringify(s)}`);
  ok(await page.evaluate(() => document.querySelector('#step-title').textContent === 'DNS lookup' && document.querySelector('#step-count').textContent === 'Step 1 of 9'), 'step text and counter update');
  ok(await until(page, () => window.RM_SIM.state().phase === 'idle' && window.RM_SIM.state().idx === 0, 15000), 'a single step finishes and then waits (does not auto-advance)');
  await sleep(1500);
  s = await state(page);
  ok(s.idx === 0, `Step must not continue by itself (idx ${s.idx})`);

  // step forward while a step is in flight snaps it to the end
  await page.click('#btn-step');
  await sleep(150);
  await page.click('#btn-step');
  s = await state(page);
  ok(s.idx === 1 && (s.phase === 'idle'), `Step during motion should complete the step: ${JSON.stringify(s)}`);

  // play, pause freezes the packet, resume continues
  await page.select('#speed', '2');
  ok((await state(page)).speed === 2, 'speed selection changes the playback speed');
  await page.click('#btn-play');
  ok((await state(page)).playing, 'Play starts playback');
  ok(await page.evaluate(() => document.querySelector('#btn-play .lbl').textContent === 'Pause'), 'Play button turns into Pause');
  // Pause only while a packet is visibly travelling, so the freeze check cannot pass vacuously.
  ok(await until(page, () => window.RM_SIM.state().phase === 'moving' && !!document.querySelector('.packet'), 20000), 'a packet is travelling after Play');
  await sleep(120);
  await page.click('#btn-play');
  ok(!(await state(page)).playing, 'Pause stops playback');
  const grab = () => page.evaluate(() => { const p = document.querySelector('.packet'); return { t: p && p.getAttribute('transform'), idx: window.RM_SIM.state().idx, phase: window.RM_SIM.state().phase }; });
  const before = await grab();
  await sleep(900);
  const after = await grab();
  ok(before.t !== null && before.phase === 'moving', `a packet must be in flight when paused: ${JSON.stringify(before)}`);
  ok(before.t === after.t && before.idx === after.idx, `the packet must freeze while paused: ${before.t} -> ${after.t}`);
  await page.click('#btn-play');                      // resume
  await sleep(500);
  const resumed = await grab();
  ok(resumed.t !== before.t || resumed.idx !== before.idx, 'the packet moves again after resuming');
  ok(await until(page, () => window.RM_SIM.state().phase === 'complete', 60000), 'playback runs to completion');
  s = await state(page);
  ok(s.idx === 8 && !s.playing, `completed state ${JSON.stringify(s)}`);
  ok(await page.evaluate(() => !document.querySelector('#sim-complete').hidden && /no request was sent/i.test(document.querySelector('#sim-complete').textContent)), 'completion message says no request was sent');
  ok(await page.evaluate(() => document.querySelector('#bar-fill').style.width === '100.0%' || document.querySelector('#bar-fill').style.width === '100%'), 'progress bar reaches 100% of the steps');
  ok(await page.evaluate(() => document.querySelector('#btn-play .lbl').textContent === 'Replay'), 'Play button offers Replay at the end');

  // order and direction of connections
  const verify = await page.evaluate(() => {
    const D = window.RM_DATA, log = window.__log;
    const expected = [];
    D.flow.steps.forEach((st) => st.path.forEach((p) => expected.push(p.edge + ':' + p.dir)));
    const parse = (d) => { const pts = []; let x = 0, y = 0; for (const m of d.matchAll(/([MLHV])\s*(-?[\d.]+)(?:[,\s]+(-?[\d.]+))?/g)) { if (m[1] === 'M' || m[1] === 'L') { x = +m[2]; y = +m[3]; } else if (m[1] === 'H') x = +m[2]; else y = +m[2]; pts.push([x, y]); } return pts; };
    // main request path, in order, no skipped or repeated connection
    const liveMain = log.live.filter((id, i, a) => a.indexOf(id) !== -1);
    const dirs = [];
    D.flow.steps.forEach((st) => st.path.forEach((p) => dirs.push(p)));
    const startsOk = [];
    log.starts.forEach((st, i) => {
      const p = dirs[i]; if (!p) { startsOk.push('extra packet ' + i); return; }
      const pts = parse(document.getElementById(p.edge).getAttribute('d'));
      const want = p.dir === 'fwd' ? pts[0] : pts[pts.length - 1];
      const m = /translate\(([-\d.]+) ([-\d.]+)\)/.exec(st.t);
      if (!m || Math.abs(+m[1] - want[0]) > 1 || Math.abs(+m[2] - want[1]) > 1 || st.rev !== (p.dir === 'rev')) startsOk.push(`${p.edge} ${p.dir}: packet began at ${st.t}`);
    });
    return { expected: expected.length, packets: log.starts.length, startsBad: startsOk, liveOrder: log.live };
  });
  ok(verify.packets === verify.expected, `packet count ${verify.packets} != connections traversed ${verify.expected}`);
  ok(verify.startsBad.length === 0, `packet start/direction mismatches: ${verify.startsBad.join('; ')}`);
  // DNS is one continuous lit connection (question and answer); the response then retraces the request in reverse.
  const wantOrder = ['e_dns', 'e_browser_cf', 'e_cf_igw', 'e_igw_alb', 'e_alb_fe', 'e_fe_int', 'e_int_be', 'e_be_rds',
    'e_be_rds', 'e_int_be', 'e_fe_int', 'e_alb_fe', 'e_igw_alb', 'e_cf_igw', 'e_browser_cf'];
  ok(JSON.stringify(verify.liveOrder) === JSON.stringify(wantOrder), `connections lit in the wrong order: ${verify.liveOrder.join(' > ')}`);
  if (shotsDir) { await page.evaluate(() => document.querySelector('#diagram').scrollIntoView()); await page.screenshot({ path: path.join(shotsDir, 'desktop-complete.png') }); }

  // restart and reset
  await page.click('#btn-restart');
  await sleep(300);
  s = await state(page);
  ok(s.idx === 0 && s.playing, `Restart begins again from step 1 and plays: ${JSON.stringify(s)}`);
  ok(await page.evaluate(() => document.querySelector('#sim-complete').hidden), 'Restart hides the completion message');
  await sleep(600);
  await page.click('#btn-reset');
  s = await state(page);
  ok(s.idx === -1 && s.phase === 'idle' && !s.playing, `Reset returns to the initial state: ${JSON.stringify(s)}`);
  const clean = await page.evaluate(() => ({ marks: document.querySelectorAll('#diagram .is-active, #diagram .is-done, #diagram .is-live').length, packets: document.querySelectorAll('.packet,.pulse').length, title: document.querySelector('#step-title').textContent, bar: document.querySelector('#bar-fill').style.width }));
  ok(clean.marks === 0 && clean.packets === 0 && clean.title === 'Press Play to follow a request' && /^0/.test(clean.bar), `Reset leaves residue: ${JSON.stringify(clean)}`);

  // jump to a step; layer toggles
  await page.click('#steps-list li:nth-child(5) button');
  s = await state(page);
  ok(s.idx === 4, `jumping to step 5 selects it (idx ${s.idx})`);
  ok(await page.evaluate(() => document.querySelectorAll('#diagram .node.is-done').length > 0), 'jumping marks earlier steps as done');
  await page.click('#layer-health');
  ok(await page.evaluate(() => document.querySelector('#diagram svg').classList.contains('hide-health') && getComputedStyle(document.querySelector('#hc_ext')).display === 'none'), 'health-check layer can be hidden');
  await page.click('#layer-security');
  ok(await page.evaluate(() => getComputedStyle(document.querySelector('#n-sg_ext')).display === 'none'), 'security-group layer can be hidden');

  // keyboard shortcuts inside the simulator
  await page.click('#btn-reset');
  await page.focus('#btn-reset');
  await page.keyboard.press('ArrowRight');
  ok((await state(page)).idx === 0, 'ArrowRight steps forward');
  ok(problems.page.length === 0 && problems.console.length === 0 && problems.external.length === 0, `errors during simulation: ${[...problems.page, ...problems.console, ...problems.external].join(' | ')}`);
  await page.close();
}

/* ------------------------------------------------------------------ 3. reduced motion */
{
  const { page } = await open({ reduced: true });
  ok(await page.evaluate(() => window.RM_SIM.reducedMotion()), 'prefers-reduced-motion is detected');
  await page.evaluate(() => document.querySelector('#architecture').scrollIntoView());
  await page.click('#btn-step');
  const r = await page.evaluate(() => ({ packets: document.querySelectorAll('.packet').length, done: document.querySelectorAll('#diagram .node.is-done').length, phase: window.RM_SIM.state().phase, idx: window.RM_SIM.state().idx }));
  ok(r.packets === 0, 'no moving packet when motion is reduced');
  ok(r.done > 0 && r.idx === 0 && r.phase === 'idle', `step completes instantly under reduced motion: ${JSON.stringify(r)}`);
  const anim = await page.evaluate(() => getComputedStyle(document.querySelector('.e-hc')).animationName);
  ok(anim === 'none', `decorative dash animation must be off (got ${anim})`);
  const reveal = await page.evaluate(() => [...document.querySelectorAll('.stage')].every((s) => getComputedStyle(s).opacity === '1'));
  ok(reveal, 'timeline items are visible immediately under reduced motion');
  await page.close();
}

/* ------------------------------------------------------------------ 4. responsive */
{
  const { page, problems } = await open({ viewport: { width: 390, height: 844, isMobile: true, deviceScaleFactor: 2 } });
  const m = await page.evaluate(() => ({ scrollW: document.documentElement.scrollWidth, innerW: window.innerWidth, simCols: getComputedStyle(document.querySelector('#sim')).gridTemplateColumns.split(' ').length, scroller: document.querySelector('.diagram-scroll').scrollWidth > document.querySelector('.diagram-scroll').clientWidth }));
  ok(m.scrollW <= m.innerW + 1, `page scrolls horizontally on a phone (${m.scrollW} > ${m.innerW})`);
  ok(m.simCols === 1, `simulator should stack on a phone (columns: ${m.simCols})`);
  ok(m.scroller, 'diagram is horizontally scrollable on a phone instead of shrinking to illegibility');
  const small = await page.evaluate(() => [...document.querySelectorAll('.btn, .steps button, .filters button, .stage-toggle')].filter((b) => { const r = b.getBoundingClientRect(); return r.width > 0 && (r.height < 28 || r.width < 28); }).length);
  ok(small === 0, `${small} tap targets are smaller than 28px`);
  if (shotsDir) { await page.screenshot({ path: path.join(shotsDir, 'mobile-top.png') }); await page.evaluate(() => { document.documentElement.style.scrollBehavior = 'auto'; document.querySelector('#architecture').scrollIntoView(); }); await sleep(300); await page.screenshot({ path: path.join(shotsDir, 'mobile-sim.png') }); }
  ok(problems.page.length === 0, `errors on mobile: ${problems.page.join(' | ')}`);
  await page.close();
}

await browser.close();
console.log(`browser tests: ${passed} passed, ${failures.length} failed`);
for (const f of failures) console.log('  FAIL: ' + f);
process.exit(failures.length ? 1 : 0);

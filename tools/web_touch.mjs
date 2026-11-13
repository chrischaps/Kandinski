// The web build played by fingers alone: desktop Chrome over CDP with touch
// emulation at a phone's size (after Flint's tools/web-touch/ipad.mjs and
// this folder's web_smoke.mjs). Begin, then the taps-only menu path, a short
// drive with two fingers down at once, the pause menu, and back out:
//   title -> HORIZON (locked: refuses) -> GRAND TOUR -> a locked event ->
//   FIRST LIGHT -> briefing BACK -> again -> START -> stick + BRAKE, DRIFT,
//   BOOST -> the menu button -> RESUME -> the menu button -> QUIT -> tour
//   BACK -> title -> ARCADE -> drive.
// A screenshot a step lands in <outDir>; the perf corner's line and the
// console's errors are printed. Each run starts from a clean browser profile,
// so from a clean save.
//   engine/target/release/flint.exe export web . --out captures/web
//   python -m http.server 8765 -d captures/web
//   node tools/web_touch.mjs "http://127.0.0.1:8765/?game=afterglow&perf=1" snapshots/web_touch [phone|tablet] [port]
// Where the fingers land is computed from the layout numbers of
// scripts/hud.rhai and config/input.toml, as tools/touch_check.py does.
// Needs Chrome at its default Windows path; edit the spawn below elsewhere.
import { spawn } from 'node:child_process';
import { writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { resolve } from 'node:path';
const [url, outRoot, size = 'phone', port = '9348'] = process.argv.slice(2);
// DPR 1 on purpose. Under Chrome's device emulation the canvas gets the real
// monitor's pixels (here 1 a CSS pixel, with --force-device-scale-factor=1)
// while the page's devicePixelRatio says the emulated number, so an emulated
// DPR 3 draws everything measured in points (the touch controls, a 44 pt row)
// three times too big: an artifact of emulation (Flint's docs/design/web.md,
// "The coordinate catch"), not what a phone does. At DPR 1 a point is a CSS
// pixel, as on a phone; what this cannot show is a phone's pixel density.
const SIZES = { phone: [844, 390, 1], tablet: [1180, 820, 1] };
const [VW, VH, DPR] = SIZES[size];
const outDir = `${outRoot}/${size}`;
mkdirSync(outDir, { recursive: true });
rmSync(resolve(outDir, 'profile'), { recursive: true, force: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const chrome = spawn('C:/Program Files/Google/Chrome/Application/chrome.exe', [
  `--remote-debugging-port=${port}`, `--user-data-dir=${resolve(outDir, 'profile')}`,
  '--enable-unsafe-webgpu', '--no-first-run', '--no-default-browser-check',
  '--no-proxy-server', '--disable-features=NetworkServiceSandbox', '--enable-features=NetworkServiceInProcess',
  '--disable-backgrounding-occluded-windows', '--disable-renderer-backgrounding',
  '--disable-background-timer-throttling', '--autoplay-policy=no-user-gesture-required',
  `--window-size=${Math.max(VW, 900)},${VH + 140}`, '--force-device-scale-factor=1', 'about:blank',
], { stdio: 'ignore' });
let targets;
for (let i = 0; i < 60; i++) {
  try { targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); break; } catch { await sleep(250); }
}
const page = targets.find((t) => t.type === 'page');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let id = 0; const pending = new Map(); const log = [];
const t0 = Date.now(); const stamp = () => ((Date.now() - t0) / 1000).toFixed(1);
ws.addEventListener('message', (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  if (m.method === 'Runtime.consoleAPICalled') log.push(`${stamp()} [${m.params.type}] ` + m.params.args.map((a) => a.value ?? a.description ?? '').join(' '));
  if (m.method === 'Runtime.exceptionThrown') log.push(`${stamp()} [exception] ` + (m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text));
});
const send = (method, params = {}, ms = 8000) => new Promise((r) => {
  const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params }));
  setTimeout(() => { if (pending.has(i)) { pending.delete(i); r({ timeout: true }); } }, ms);
});
const ev = async (expression, userGesture = false, ms = 8000) => {
  const r = await send('Runtime.evaluate', { expression, returnByValue: true, userGesture }, ms);
  return r.timeout ? '(timeout)' : r.result?.result?.value;
};
let shotN = 0;
const shot = async (n) => {
  const s = await send('Page.captureScreenshot', { format: 'png' }, 6000);
  const name = `${String(++shotN).padStart(2, '0')}_${n}`;
  if (s.result) writeFileSync(`${outDir}/${name}.png`, Buffer.from(s.result.data, 'base64'));
  log.push(`${stamp()} [shot] ${name}`);
};
// fingers: every dispatch carries all that are down, as a real screen reports them
const fingers = new Map();
const flush = (kind) => {
  const touchPoints = [...fingers].map(([fid, [x, y]]) => ({ x, y, id: fid, radiusX: 8, radiusY: 8, force: 1 }));
  return send('Input.dispatchTouchEvent', touchPoints.length ? { type: kind, touchPoints } : { type: 'touchEnd', touchPoints: [] }, 2000);
};
let OX = 0, OY = 0;       // the canvas's corner in the viewport
const down = (f, p) => { fingers.set(f, [p[0] + OX, p[1] + OY]); return flush('touchStart'); };
const move = (f, p) => { fingers.set(f, [p[0] + OX, p[1] + OY]); return flush('touchMove'); };
// One finger of several lifting: Chrome wants a touchEnd that lists the
// finger that lifts (found by trial: a touchMove without it leaves it down, a
// touchEnd listing the others lifts those; console.log's [pointer] lines show
// which pointer really came up).
const up = async (f) => {
  const at = fingers.get(f);
  fingers.delete(f);
  const r = await send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: fingers.size && at ? [{ x: at[0], y: at[1], id: f, radiusX: 8, radiusY: 8, force: 1 }] : [] }, 2000);
  if (r.error) log.push(`${stamp()} [harness] lift ${f}: ${r.error.message}`);
  return r;
};
const tap = async (p, name, wait = 1000) => { await down(1, p); await sleep(90); await up(1); await sleep(wait); if (name) await shot(name); };
const glide = async (f, from, to, ms) => { const n = Math.max(2, Math.round(ms / 33)); for (let k = 1; k <= n; k++) { await move(f, [from[0] + (to[0] - from[0]) * k / n, from[1] + (to[1] - from[1]) * k / n]); await sleep(33); } };
const perf = () => ev(`document.getElementById('perf')?.dataset.line || document.getElementById('perf')?.textContent || 'no perf corner'`);

await send('Runtime.enable'); await send('Page.enable');
await send('Emulation.setDeviceMetricsOverride', { width: VW, height: VH, deviceScaleFactor: DPR, mobile: true, screenOrientation: { type: 'landscapePrimary', angle: 90 } });
await send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
await send('Emulation.setUserAgentOverride', {
  userAgent: 'Mozilla/5.0 (Linux; Android 15; Pixel 8 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36',
  platform: 'Linux armv81',
});
// every pointer event the page hears, for the log: which finger went down and came up, and when
await send('Page.addScriptToEvaluateOnNewDocument', { source: `for (const t of ['pointerdown', 'pointerup', 'pointercancel']) addEventListener(t, (e) => console.log('[pointer] ' + t + ' id=' + e.pointerId + ' ' + e.pointerType + ' ' + Math.round(e.clientX) + ',' + Math.round(e.clientY)), true);` });
await send('Page.navigate', { url });
for (let i = 0; i < 480; i++) {
  const ok = await ev(`!!document.querySelector('#gate[data-ready]')`);
  if (ok === true) break;
  await sleep(250);
}
await sleep(1500);
await shot('gate');
console.log('gate says:', await ev(`(document.getElementById('gate')?.innerText || '').replace(/\\s+/g, ' ').slice(0, 400)`));
// the gate's Begin, by a finger where it is (falling back to a click)
const b = await ev(`(() => { const e = document.getElementById('begin'); if (!e) return null; const r = e.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
if (b) { await down(1, b); await sleep(90); await up(1); await sleep(600); }
if (await ev(`!!document.querySelector('#gate') && getComputedStyle(document.getElementById('gate')).display !== 'none' && !document.body.classList.contains('playing')`) === true) {
  await ev(`document.getElementById('begin')?.click()`, true);
}
await sleep(7000);
const rect = JSON.parse(await ev(`(() => { const c = document.querySelector('canvas'); const r = c.getBoundingClientRect(); return JSON.stringify([r.x, r.y, r.width, r.height, innerWidth, innerHeight, devicePixelRatio, matchMedia('(pointer: coarse)').matches, !!document.fullscreenElement]); })()`));
console.log('canvas x y w h, viewport, dpr, coarse pointer, fullscreen:', rect.join(' '));
[OX, OY] = rect;
// ?perf=1's panel lies over the top right, where the menu button is: let fingers through it
await ev(`(() => { const p = document.getElementById('perf'); if (p) p.style.pointerEvents = 'none'; })()`);
const w = rect[2], h = rect[3];

// the layout, from hud.rhai's numbers (points; the canvas is points wide)
const u = h / 720, cx = w / 2, TMIN = 44;
const pitch = Math.max(59 * u, TMIN + 2), my = Math.min(h * 0.50, h * 0.905 - 4 * pitch);
const title = (i) => [cx, my + i * pitch - 4 * u + (pitch - 2) / 2];   // ARCADE, GRAND TOUR, HORIZON, SETTINGS
const x0 = 40 * u, W = w - 80 * u, gap = 10 * u, cw = (W - 4 * gap) / 5, top = 104 * u, ch = 78 * u;
const card = (leg, row) => [x0 + leg * (cw + gap) + cw / 2, top + 48 * u + row * (ch + 8 * u) + ch / 2];
const tourBack = [x0 + Math.max(104 * u, 2 * TMIN) / 2, 54 * u];
const by = h / 2 - 220 * u + 400 * u + 12 * u, bh = Math.max(44 * u, TMIN), bw = Math.max(220 * u, 3 * TMIN);
const briefBack = [cx - 14 * u - bw / 2, by + bh / 2], briefStart = [cx + 14 * u + bw / 2, by + bh / 2];
const pause = (k) => [cx, h * 0.21 + 110 * u + k * (bh + 12 * u) + bh / 2];   // RESUME, RESTART, SETTINGS, QUIT
// config/input.toml [touch_controls] (the page's safe-area insets are 0 here)
const stick = [112, h - 112], brake = [w - 88, h - 92], drift = [w - 190, h - 150], boost = [w - 84, h - 204], menu = [cx + 150, 36];
const full = (0.12 + 0.88) * 56 + 20;

await shot('title_before_a_touch');
await tap(title(2), 'title_horizon_refuses');
await tap(title(1), 'tour');
await tap(card(1, 0), 'tour_locked_event_refuses');
await tap(card(0, 0), 'briefing');
await tap(briefBack, 'briefing_back_to_tour');
await tap(card(0, 0), 'briefing_again');
await tap(briefStart, 'countdown', 1600);
await sleep(2600);                                   // the rest of the countdown
await shot('drive_no_fingers');                      // auto gas: nobody is touching
const p0 = await perf();
await down(1, stick); await sleep(400);
await glide(1, stick, [stick[0] + 30, stick[1]], 200); await sleep(500);
await shot('drive_stick_right');
await glide(1, [stick[0] + 30, stick[1]], [stick[0] - 30, stick[1]], 300); await sleep(500);
await glide(1, [stick[0] - 30, stick[1]], stick, 200);
await sleep(2500);
await down(2, brake); await sleep(700);              // two fingers down
await shot('drive_stick_and_brake');
await up(2); await sleep(2500);
await glide(1, stick, [stick[0] + full, stick[1]], 120);
await down(2, drift); await sleep(400); await up(2); // a drift: the stick into it, DRIFT for 0.4 s
await sleep(900);
await shot('drive_drift');
await sleep(1200);
await glide(1, [stick[0] + full, stick[1]], stick, 150);
await sleep(1500);
await down(2, boost); await sleep(900);
await shot('drive_boost');
await up(2);
await sleep(600);
const p1 = await perf();
await down(2, menu); await sleep(90); await up(2);   // the menu button, the stick still held
await sleep(500); await up(1); await sleep(500);
await shot('pause');
await tap(pause(0), 'pause_resume', 1200);
await down(2, menu); await sleep(90); await up(2); await sleep(900);
await shot('pause_again');
await tap(pause(3), 'pause_quit_to_tour', 1300);
await tap(tourBack, 'tour_back_to_title', 1300);
await tap(title(0), 'arcade_countdown', 2200);
await sleep(2600);
await down(1, stick); await glide(1, stick, [stick[0] + 24, stick[1]], 200);
await sleep(5000);
await shot('arcade_drive');
await up(1);
await sleep(4000);
const p2 = await perf();
await shot('arcade_drive_later');
console.log('perf corner, start of the event:', p0);
console.log('perf corner, after its drive:  ', p1);
console.log('perf corner, in the arcade run: ', p2);
writeFileSync(`${outDir}/console.log`, log.join('\n'));
const bad = log.filter((l) => /\[(error|exception)\]|panick|WARN.*script|script.*(WARN|error)/i.test(l));
console.log(`console lines: ${log.length}, errors/panics/script warnings: ${bad.length}`);
for (const l of bad.slice(0, 12)) console.log('  ' + l.slice(0, 300));
await send('Browser.close');
chrome.kill();
process.exit(0);

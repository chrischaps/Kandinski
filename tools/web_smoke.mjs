// Smoke test of the web build in desktop Chrome over CDP (after Flint's
// tools/web-touch/ipad.mjs): load the page, press Begin, start ARCADE, hold
// the throttle, steer, and save screenshots and the console.
//   python -m http.server 8765 -d captures/web
//   node tools/web_smoke.mjs "http://127.0.0.1:8765/?game=afterglow&perf=1" snapshots/web
import { spawn } from 'node:child_process';
import { writeFileSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
const [url, outDir, port = '9347'] = process.argv.slice(2);
mkdirSync(outDir, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const chrome = spawn('C:/Program Files/Google/Chrome/Application/chrome.exe', [
  `--remote-debugging-port=${port}`, `--user-data-dir=${resolve(outDir, 'profile')}`,
  '--enable-unsafe-webgpu', '--no-first-run', '--no-default-browser-check',
  '--disable-backgrounding-occluded-windows', '--disable-renderer-backgrounding',
  '--disable-background-timer-throttling', '--autoplay-policy=no-user-gesture-required',
  '--window-size=1300,820', '--force-device-scale-factor=1', 'about:blank',
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
const ev = async (expression, userGesture = false) => {
  const r = await send('Runtime.evaluate', { expression, returnByValue: true, userGesture });
  return r.timeout ? '(timeout)' : r.result?.result?.value;
};
const shot = async (n) => { const s = await send('Page.captureScreenshot', { format: 'png' }, 6000); if (s.result) writeFileSync(`${outDir}/${n}.png`, Buffer.from(s.result.data, 'base64')); };
const VK = { Enter: 13, KeyW: 87, KeyD: 68, KeyA: 65, Space: 32, ArrowDown: 40, ShiftLeft: 16 };
const keyOf = (code) => ({ Enter: 'Enter', KeyW: 'w', KeyD: 'd', KeyA: 'a', Space: ' ', ArrowDown: 'ArrowDown', ShiftLeft: 'Shift' }[code]);
const key = (type, code) => send('Input.dispatchKeyEvent', { type, code, key: keyOf(code), windowsVirtualKeyCode: VK[code], nativeVirtualKeyCode: VK[code] });
const tap = async (code) => { await key('rawKeyDown', code); await sleep(80); await key('keyUp', code); };

await send('Runtime.enable'); await send('Page.enable');
await send('Page.bringToFront');
await send('Page.navigate', { url });
await sleep(6000);
await shot('1_gate');
// press the page's Begin
const begun = await ev(`(() => { const b = [...document.querySelectorAll('button')].find(b => /begin|play|start/i.test(b.textContent)); if (b) { b.click(); return b.textContent.trim(); } return 'no button: ' + [...document.querySelectorAll('button')].map(b => b.textContent.trim()).join('|'); })()`, true);
console.log('begin:', begun);
await sleep(9000);
await shot('2_title');
await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: 650, y: 400, button: 'left', clickCount: 1 });
await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: 650, y: 400, button: 'left', clickCount: 1 });
await tap('Enter');           // ARCADE
await sleep(4500);
await shot('3_countdown');
await key('rawKeyDown', 'KeyW');
await sleep(7000);
await shot('4_drive');
await key('rawKeyDown', 'KeyD'); await sleep(500); await key('keyUp', 'KeyD');
await sleep(8000);
await shot('5_drive');
console.log('perf corner:', await ev(`(() => { const e = [...document.querySelectorAll('pre,div,span')].find(e => /fps|ms/.test(e.textContent) && e.children.length === 0); return e ? e.textContent.slice(0, 400) : 'none'; })()`));
await key('keyUp', 'KeyW');
writeFileSync(`${outDir}/console.log`, log.join('\n'));
const bad = log.filter((l) => /\[(error|exception)\]|panick|WARN.*script/i.test(l));
console.log(`console lines: ${log.length}, errors/panics/script warnings: ${bad.length}`);
for (const l of bad.slice(0, 12)) console.log('  ' + l.slice(0, 300));
await send('Browser.close');
chrome.kill();
process.exit(0);

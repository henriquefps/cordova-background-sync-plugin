// Shared helpers for the Android test scripts: adb, the app's WebView over the
// Chrome DevTools Protocol, the plugin API as promises, and the backoffice.
//
// Needs Node 22+ (global WebSocket and fetch), adb on PATH or ANDROID_HOME set,
// a debug build of the demo app (WebView debugging is on in debug builds) and
// the backoffice running (node backoffice/server.mjs).
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

export const HERE = path.dirname(fileURLToPath(import.meta.url));
export const DEMO_DIR = path.join(HERE, '..');
export const APP_ID = 'com.hfps.fieldaudit';
export const AUDIT_ID = 'AUD-2026-0418';
export const PORT = Number(process.env.BACKOFFICE_PORT || 8791);
export const BACKOFFICE = `http://localhost:${PORT}`;
// The emulator reaches the host at 10.0.2.2.
export const SERVER_URL = process.env.SERVER_URL || `http://10.0.2.2:${PORT}`;
export const DEVTOOLS_PORT = Number(process.env.DEVTOOLS_PORT || 9333);
export const OUT_DIR = process.env.OUT_DIR || path.join(os.tmpdir(), 'bgsync-android-tests');
fs.mkdirSync(OUT_DIR, { recursive: true });

const ADB = process.env.ANDROID_HOME ? path.join(process.env.ANDROID_HOME, 'platform-tools', 'adb') : 'adb';
const SERIAL = process.env.ANDROID_SERIAL ? ['-s', process.env.ANDROID_SERIAL] : [];

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const log = (...a) => console.log(`[${new Date().toISOString().slice(11, 19)}]`, ...a);

export function adb(...args) {
  return execFileSync(ADB, [...SERIAL, ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }).trim();
}
export const shell = (cmd) => adb('shell', cmd);
export const runAs = (cmd) => shell(`run-as ${APP_ID} sh -c '${cmd.replace(/'/g, "'\\''")}'`);
export const key = (k) => shell(`input keyevent ${k}`);

export async function waitFor(fn, { timeout = 60000, interval = 1000, what = 'condition' } = {}) {
  const until = Date.now() + timeout;
  let last;
  while (Date.now() < until) {
    try {
      last = await fn();
      if (last) return last;
    } catch (e) {
      last = e;
    }
    await sleep(interval);
  }
  throw new Error(`Timed out waiting for ${what} (last: ${last instanceof Error ? last.message : JSON.stringify(last)})`);
}

// ------------------------------------------------------------------ device ---
export const appPid = () => {
  try { return shell(`pidof ${APP_ID}`).split(/\s+/)[0] || null; } catch { return null; }
};
// Screen on and keyguard dismissed, so a launched app is really visible.
export function wakeAndUnlock() {
  key('KEYCODE_WAKEUP');
  try { shell('wm dismiss-keyguard'); } catch { /* not locked */ }
}
export function launchApp() {
  wakeAndUnlock();
  shell(`monkey -p ${APP_ID} -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1`);
}
export const forceStop = () => shell(`am force-stop ${APP_ID}`);
export const home = () => key('KEYCODE_HOME');
export function setAirplane(on) {
  shell(`cmd connectivity airplane-mode ${on ? 'enable' : 'disable'}`);
}
export function setWifi(on) {
  shell(`svc wifi ${on ? 'enable' : 'disable'}`);
}
export function setData(on) {
  shell(`svc data ${on ? 'enable' : 'disable'}`);
}
export function screen(on) {
  key(on ? 'KEYCODE_WAKEUP' : 'KEYCODE_SLEEP');
}
export function grantNotifications(granted) {
  shell(`pm ${granted ? 'grant' : 'revoke'} ${APP_ID} android.permission.POST_NOTIFICATIONS`);
}
// Drops the plugin queue, WorkManager state and preferences. Photos stay.
export function resetApp() {
  try { setAirplane(false); } catch { /* ignore */ }
  try { setWifi(true); setData(true); } catch { /* ignore */ }
  forceStop();
  shell(`run-as ${APP_ID} rm -rf databases shared_prefs no_backup app_webview/Default/Local\\ Storage`);
  try { shell(`cmd notification cancel_all ${APP_ID}`); } catch { /* older images */ }
}
export function screenshot(name) {
  const file = path.join(OUT_DIR, `${name}.png`);
  execFileSync(ADB, [...SERIAL, 'exec-out', 'screencap', '-p'], { maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', fs.openSync(file, 'w'), 'inherit'] });
  return file;
}
export function logcatClear() { adb('logcat', '-c'); }
export function logcat(filter = 'BackgroundSyncPlugin|WM-|ActivityManager.*fieldaudit|SystemForeground|ForegroundService') {
  const all = adb('logcat', '-d', '-v', 'time');
  const re = new RegExp(filter);
  return all.split('\n').filter((l) => re.test(l)).join('\n');
}

// The app's notifications as the system sees them (id, ongoing flag, text).
export function notifications() {
  const out = shell('dumpsys notification --noredact');
  const recs = [];
  const blocks = out.split(/\n\s*NotificationRecord\(/).slice(1);
  for (const b of blocks) {
    if (!b.includes(`pkg=${APP_ID}`)) continue;
    const id = (b.match(/\bid=(\d+)/) || [])[1];
    // Numeric (0x62) on older images, symbolic (ONGOING_EVENT|FOREGROUND_SERVICE) on newer ones.
    const flags = (b.match(/\n\s+flags=(\S+)/) || [])[1] || '';
    const title = (b.match(/android\.title=String \((.*)\)/) || [])[1];
    const text = (b.match(/android\.text=String \((.*)\)/) || [])[1];
    const progress = (b.match(/android\.progress=Integer \((\d+)\)/) || [])[1];
    const channel = (b.match(/channel=([\w.]+)/) || [])[1] || (b.match(/mChannelId=([\w.]+)/) || [])[1];
    const num = /^(0x[0-9a-f]+|\d+)$/i.test(flags) ? Number(flags) : null;
    const ongoing = num !== null ? !!(num & 0x2) : flags.includes('ONGOING_EVENT');
    const fgs = num !== null ? !!(num & 0x40) : flags.includes('FOREGROUND_SERVICE');
    if (recs.some((r) => r.id === Number(id))) continue;
    recs.push({ id: Number(id), ongoing, fgs, title, text, progress: progress ? Number(progress) : undefined, channel });
  }
  return recs;
}

// ------------------------------------------------------------- the webview ---
let ws = null;
let msgId = 0;
const pending = new Map();

function devtoolsSocket() {
  const pid = appPid();
  if (!pid) throw new Error('App is not running');
  const unix = shell('cat /proc/net/unix');
  const m = unix.match(new RegExp(`@(webview_devtools_remote_${pid})\\b`));
  if (!m) throw new Error(`No WebView devtools socket for pid ${pid} (debug build?)`);
  return m[1];
}

export async function connect({ timeout = 30000 } = {}) {
  disconnect();
  const target = await waitFor(async () => {
    const sock = devtoolsSocket();
    adb('forward', `tcp:${DEVTOOLS_PORT}`, `localabstract:${sock}`);
    const pages = await (await fetch(`http://localhost:${DEVTOOLS_PORT}/json`)).json();
    return pages.find((p) => p.type === 'page' && p.webSocketDebuggerUrl);
  }, { timeout, what: 'WebView devtools target' });
  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = (e) => reject(new Error(`devtools socket: ${e.message || 'error'}`));
  });
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(msg.error.message));
      else resolve(msg.result);
    }
  };
  ws.onclose = () => {
    for (const { reject } of pending.values()) reject(new Error('devtools socket closed'));
    pending.clear();
  };
  // Wait for cordova and the plugin, then hook the event recorder.
  await waitFor(() => evaluate('!!(window.cordova && cordova.plugins && cordova.plugins.BackgroundSyncPlugin)'), { timeout, what: 'cordova plugin' });
  await evaluate(RECORDER);
  // The demo app initializes the plugin on start; let it finish so a test's own
  // initialize() is not overwritten by the app's.
  try {
    await waitFor(() => evaluate('cordova.plugins.BackgroundSyncPlugin.isInitialized === true'), { timeout: 8000, interval: 300, what: 'app initialize' });
  } catch { /* the app may not initialize (non-demo app); carry on */ }
}

export function disconnect() {
  if (ws) {
    try { ws.close(); } catch { /* ignore */ }
    ws = null;
  }
}

function cdp(method, params = {}) {
  if (!ws || ws.readyState !== 1) return Promise.reject(new Error('Not connected to the WebView'));
  const id = ++msgId;
  ws.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

export async function evaluate(expression) {
  const r = await cdp('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) {
    throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
  }
  return r.result.value;
}

// Records every plugin event in window.__bgEvents without replacing the app's
// listeners (the plugin looks listeners up by name on each event).
const RECORDER = `(() => {
  const P = cordova.plugins.BackgroundSyncPlugin;
  window.__bgEvents = window.__bgEvents || [];
  if (window.__bgHooked) return true;
  window.__bgHooked = true;
  const names = ['onStarted','onProgress','onFailed','onCompleted','onStartedDownload','onProgressDownload','onFailedDownload','onStarted_download','onProgress_download','onFailed_download','onDatabaseReset'];
  const wrap = () => {
    P.listeners = P.listeners || {};
    for (const n of names) {
      const orig = P.listeners[n];
      if (orig && orig.__rec) continue;
      const f = function (e) { window.__bgEvents.push({ t: Date.now(), ...e }); if (orig) return orig(e); };
      f.__rec = true;
      P.listeners[n] = f;
    }
  };
  if (!P.listeners || Object.keys(P.listeners).length === 0) P.registerListeners({});
  wrap();
  // The app may register its listeners later; keep wrapping.
  const orig = P.registerListeners.bind(P);
  P.registerListeners = function (l) { orig(l); wrap(); };
  return true;
})()`;

// Event times are converted to the host clock (the emulator clock can drift by minutes),
// so callers can pass a host Date.now() as `since`.
export async function events(since = 0) {
  const before = Date.now();
  const r = await evaluate('({ now: Date.now(), events: window.__bgEvents })');
  const offset = Math.round((before + Date.now()) / 2) - r.now;
  return r.events.map((e) => ({ ...e, t: e.t + offset })).filter((e) => e.t >= since);
}
export const clearEvents = () => evaluate('window.__bgEvents.length = 0, true');

// Calls a plugin method: plugin('getQueuedRecords'), plugin('enqueueRecord', {...}).
export function plugin(method, ...args) {
  return evaluate(`new Promise((resolve, reject) => {
    cordova.plugins.BackgroundSyncPlugin[${JSON.stringify(method)}](...${JSON.stringify(args)}, resolve, (e) => reject(new Error(String(e))));
  })`);
}

export const DEFAULT_CONFIG = {
  serverUrl: SERVER_URL,
  syncOnlyOnWifi: false,
  syncOnlyWhenCharging: false,
  enableNotifications: true,
  autoDeleteCompleted: false,
  showDebugLogs: true,
  headers: { 'X-Api-Key': 'demo-device-key' },
  notificationTexts: {
    progressTitle: 'Syncing audit photos',
    progressBody: 'Photo {current} of {total} ({percentage}%)',
    preparingBody: 'Preparing the photo queue',
    successTitle: 'Audit synced',
    successBody: 'All photos are on the server.',
    failureTitle: 'Sync paused',
    failureBody: 'Upload interrupted. The queue resumes on its own when the device is back online.',
  },
};
export const initialize = (overrides = {}) => plugin('initialize', { ...DEFAULT_CONFIG, ...overrides });

// The app's private files dir, as the app sees it.
export const filesDir = () => evaluate(`(async () => {
  const fsPlugin = window.Capacitor && Capacitor.Plugins && Capacitor.Plugins.Filesystem;
  if (fsPlugin) return (await fsPlugin.getUri({ directory: 'DATA', path: '' })).uri.replace(/\\/$/, '');
  return 'file:///data/user/0/${APP_ID}/files';
})()`);

// The demo audit's photos, as the app queues them.
export function auditPhotos() {
  const data = JSON.parse(fs.readFileSync(path.join(DEMO_DIR, 'app', 'src', 'data', 'audit.json'), 'utf8'));
  const main = data.audits[0];
  return main.areas.flatMap((a) => a.findings.flatMap((f) => f.photos.map((p) => ({ ...p, findingId: f.id, areaId: a.id, auditId: main.id }))));
}

// Queues photos in the page itself (one CDP round trip, not 336).
export async function enqueuePhotos(photos, base) {
  const records = photos.map((p) => ({
    id: p.id,
    endpoint: 'api/v1/audits/photos',
    payload: JSON.stringify({ auditId: p.auditId, areaId: p.areaId, findingId: p.findingId, photoId: p.id, fileName: p.name, bytes: p.bytes, takenAt: p.takenAt }),
    filePath: `${base}/audits/${p.auditId}/photos/${p.file}`,
  }));
  return evaluate(`(async () => {
    const P = cordova.plugins.BackgroundSyncPlugin;
    const recs = ${JSON.stringify(records)};
    for (const r of recs) await new Promise((res, rej) => P.enqueueRecord(r, res, rej));
    return recs.length;
  })()`);
}

// md5 of every photo on the device, keyed by file name.
export function devicePhotoMd5() {
  const out = runAs(`cd files/audits/${AUDIT_ID}/photos && md5sum *`);
  const map = {};
  for (const line of out.split('\n')) {
    const [sum, name] = line.trim().split(/\s+/);
    if (name) map[name] = sum;
  }
  return map;
}

// --------------------------------------------------------------- backoffice ---
export async function bo(pathname, { method = 'GET', body } = {}) {
  const r = await fetch(BACKOFFICE + pathname, { method, body: body === undefined ? undefined : JSON.stringify(body) });
  return r.json();
}
export const boReset = () => bo('/api/reset', { method: 'POST' });
export const boState = () => bo('/api/state');
export const boLog = () => bo('/api/test/log');
export const setFaults = (rules) => bo('/api/faults', { method: 'POST', body: rules });
export const clearFaults = () => bo('/api/faults', { method: 'DELETE' });
export const setRate = (mbps) => bo(`/api/rate?mbps=${mbps}`, { method: 'POST' });

// ------------------------------------------------------------------ results ---
const results = [];
export function record(name, expected, observed, pass) {
  results.push({ name, expected, observed, pass });
  log(`${pass ? 'PASS' : 'FAIL'} ${name}: ${observed}`);
}
export function writeResults(file) {
  const out = path.join(OUT_DIR, file);
  fs.writeFileSync(out, JSON.stringify(results, null, 2));
  log(`Results: ${out}`);
  return results;
}

// Helpers for the iOS simulator tests: drive a test build of the app through
// the backoffice control channel (TEST_API=1), inspect the backoffice and the
// simulator, and record results.
import { execFileSync, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const DEMO_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
export const PORT = Number(process.env.BACKOFFICE_PORT || 8791);
export const BASE = `http://localhost:${PORT}`;
export const APP_ID = 'com.hfps.fieldaudit';
export const AUDIT = JSON.parse(fs.readFileSync(path.join(DEMO_DIR, 'app/src/data/audit.json'), 'utf8')).audits[0];
export const PHOTOS = AUDIT.areas.flatMap((a) => a.findings.flatMap((f) => f.photos));
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export const UDID = process.env.SIM_UDID || execFileSync('bash', ['-c', `source "${DEMO_DIR}/scripts/env.sh" && ios_sim_udid`]).toString().trim();

// ---------------------------------------------------------------- backoffice
export async function http(method, p, body) {
  const res = await fetch(BASE + p, { method, body: body === undefined ? undefined : JSON.stringify(body), headers: { 'Content-Type': 'application/json' } });
  const text = await res.text();
  try { return JSON.parse(text); } catch { return text; }
}
export const serverState = () => http('GET', '/api/state');
export const testLog = () => http('GET', '/api/test/log');
export const setFaults = (rules) => http('POST', '/api/fault', { rules });
export async function resetServer() {
  await http('POST', '/api/reset');
  await http('POST', '/api/test/reset');
}

// ------------------------------------------------------------ remote control
export async function cmd(c, timeoutMs = 60000) {
  const r = await http('POST', '/api/ctl/cmd', { ...c, timeoutMs });
  if (!r.ok) throw new Error(`${c.kind} ${c.method || ''}: ${typeof r.error === 'object' ? JSON.stringify(r.error) : r.error}`);
  return r.value;
}
export const plugin = (method, ...args) => cmd({ kind: 'plugin', method, args });
// Resolves to { ok, value | error } instead of throwing.
export const tryPlugin = (method, ...args) => http('POST', '/api/ctl/cmd', { kind: 'plugin', method, args, timeoutMs: 30000 });
export const app = (method, ...args) => cmd({ kind: 'app', method, args });
export const evalApp = (code, timeoutMs) => cmd({ kind: 'eval', code }, timeoutMs);

let cursor = 0;
export async function markEvents() {
  cursor = (await http('GET', `/api/ctl/events?since=${1e12}`)).next;
  return cursor;
}
export async function eventsSince(since = cursor) {
  return (await http('GET', `/api/ctl/events?since=${since}`)).events.filter((e) => e.name !== 'testControlReady');
}
export async function waitFor(pred, { timeoutMs = 60000, everyMs = 500, what = 'condition' } = {}) {
  const end = Date.now() + timeoutMs;
  for (;;) {
    const v = await pred();
    if (v) return v;
    if (Date.now() > end) throw new Error(`timeout waiting for ${what}`);
    await sleep(everyMs);
  }
}
export const waitEvent = (name, opts = {}) =>
  waitFor(async () => (await eventsSince(opts.since ?? cursor)).find((e) => e.name === name && (!opts.where || opts.where(e.data))), { what: name, ...opts });

// Waits until the app answers on the control channel (after a launch).
export async function waitAppReady(timeoutMs = 30000) {
  await waitFor(async () => {
    const r = await http('POST', '/api/ctl/cmd', { kind: 'ping', timeoutMs: 2000 });
    return r.ok;
  }, { timeoutMs, everyMs: 300, what: 'app control channel' });
}

// ----------------------------------------------------------------- simulator
export const simctl = (...args) => spawnSync('xcrun', ['simctl', ...args], { encoding: 'utf8' });
export function launch() {
  const r = simctl('launch', UDID, APP_ID);
  return Number((r.stdout.match(/:\s*(\d+)/) || [])[1]);
}
export const terminate = () => simctl('terminate', UDID, APP_ID);
// The simulator has no scriptable Home button; bringing Settings to the front
// moves the app to the background the same way.
export const goHome = () => simctl('launch', UDID, 'com.apple.Preferences');
export const foreground = () => launch();
export function appPid() {
  const r = spawnSync('pgrep', ['-f', `${APP_ID}.*App.app/App$|/App.app/App$`], { encoding: 'utf8' });
  const pids = r.stdout.trim().split('\n').filter(Boolean).map(Number);
  return pids.length ? Math.max(...pids) : null;
}
export const container = () => simctl('get_app_container', UDID, APP_ID, 'data').stdout.trim();
export const screenshot = (file) => simctl('io', UDID, 'screenshot', file);

// Physical footprint in MB of the app process (the simulator app is a Mac process).
export function footprintMB(pid = appPid()) {
  if (!pid) return null;
  const r = spawnSync('footprint', ['-p', String(pid)], { encoding: 'utf8' });
  const m = r.stdout.match(/Footprint:\s*([\d.]+)\s*(KB|MB|GB)/);
  if (!m) return null;
  const v = Number(m[1]);
  return m[2] === 'GB' ? v * 1024 : m[2] === 'KB' ? v / 1024 : v;
}

// ------------------------------------------------------------------ checking
export const md5File = (f) => crypto.createHash('md5').update(fs.readFileSync(f)).digest('hex');
export function md5Report() {
  // Same DATA_DIR as the backoffice when it runs with one.
  const dir = path.join(process.env.DATA_DIR ? path.resolve(process.env.DATA_DIR) : path.join(DEMO_DIR, 'backoffice/data'), AUDIT.id);
  let match = 0; const missing = []; const bad = [];
  for (const p of PHOTOS) {
    const got = path.join(dir, `${p.id}.jpg`);
    if (!fs.existsSync(got)) { missing.push(p.id); continue; }
    if (md5File(got) === md5File(path.join(DEMO_DIR, 'seed/out/photos', p.file))) match++; else bad.push(p.id);
  }
  return { match, missing: missing.length, bad };
}

// Count the plugin queue rows by status, straight from the plugin database.
export async function queueCounts(table = 'sync_queue') {
  const rows = await plugin('executeRawQuery', `SELECT Status AS s, COUNT(*) AS n FROM ${table} GROUP BY Status`, []);
  return Object.fromEntries(rows.map((r) => [r.s, Number(r.n)]));
}

export function summarize(events) {
  const counts = {};
  for (const e of events) counts[e.name] = (counts[e.name] || 0) + 1;
  return counts;
}

// ------------------------------------------------------------- app helpers
export const DEFAULT_INIT = {
  serverUrl: BASE,
  syncOnlyOnWifi: false,
  enableNotifications: true,
  autoDeleteCompleted: false,
  encryptDatabase: false,
  showDebugLogs: true,
  headers: { 'X-Api-Key': 'demo-device-key' },
};
export const init = (overrides = {}) => plugin('initialize', { ...DEFAULT_INIT, ...overrides });

// Waits until no sync run is active: the last start-like event has a later
// completed/failed event, or nothing happened for quietMs.
export async function waitIdle(quietMs = 3000, timeoutMs = 600000) {
  let last = (await http('GET', `/api/ctl/events?since=${1e12}`)).next;
  let lastChange = Date.now();
  const end = Date.now() + timeoutMs;
  for (;;) {
    await sleep(500);
    const n = (await http('GET', `/api/ctl/events?since=${1e12}`)).next;
    if (n !== last) { last = n; lastChange = Date.now(); }
    if (Date.now() - lastChange >= quietMs) return;
    if (Date.now() > end) throw new Error('timeout waiting for idle');
  }
}

// Clean slate for a case: no run in progress, empty queues, default settings,
// empty backoffice.
export async function fresh(initOverrides) {
  await plugin('cancelSync').catch(() => {});
  await waitIdle(2500);
  await init(initOverrides);
  await plugin('clearQueue');
  await plugin('clearDownloadQueue');
  await http('POST', '/api/rate?mbps=0');
  await resetServer();
  await markEvents();
}

// Writes a file of `bytes` pseudo-random bytes into the app's tmp dir and
// returns { path, uri, md5 }.
export function makeFile(name, bytes) {
  const dir = path.join(container(), 'tmp', 'tests');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, name);
  const chunk = crypto.randomBytes(1 << 20);
  const fd = fs.openSync(file, 'w');
  for (let left = bytes; left > 0; left -= chunk.length) fs.writeSync(fd, chunk, 0, Math.min(left, chunk.length));
  fs.closeSync(fd);
  return { path: file, uri: 'file://' + file, md5: md5File(file) };
}

// Samples the app's memory footprint until stop() is called.
export function memorySampler(everyMs = 1000) {
  const samples = [];
  const t = setInterval(() => { const mb = footprintMB(); if (mb) samples.push(mb); }, everyMs);
  return {
    stop() {
      clearInterval(t);
      return { samples: samples.length, startMB: samples[0], peakMB: Math.max(...samples), endMB: samples[samples.length - 1] };
    },
  };
}

// A TCP proxy in front of the backoffice. Pointing the plugin's serverUrl at
// it and closing it is a real connection loss for the plugin, while the
// control channel keeps talking to the backoffice directly.
export function proxy(listenPort, targetPort = PORT) {
  const sockets = new Set();
  let server = null;
  const api = {
    url: `http://localhost:${listenPort}`,
    start() {
      return new Promise((resolve) => {
        server = net.createServer((c) => {
          const up = net.connect(targetPort, '127.0.0.1');
          sockets.add(c); sockets.add(up);
          c.pipe(up); up.pipe(c);
          const done = () => { c.destroy(); up.destroy(); sockets.delete(c); sockets.delete(up); };
          c.on('error', done); up.on('error', done); c.on('close', done); up.on('close', done);
        });
        server.listen(listenPort, resolve);
      });
    },
    stop() {
      return new Promise((resolve) => {
        for (const s of sockets) s.destroy();
        sockets.clear();
        if (!server) return resolve();
        server.close(() => resolve());
        server = null;
      });
    },
  };
  return api;
}

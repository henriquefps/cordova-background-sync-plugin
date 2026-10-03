#!/usr/bin/env node
// Record the raw demo takes: one continuous, real sync of the seeded audit,
// split into takes. For every take this writes, to OUT/<take-id>/:
//   phone.mp4       the emulator screen (adb screenrecord), 1080x2400
//   backoffice.mp4  the live backoffice page (Chromium screencast), 1440x900
//   events.json     [{ t, event }] with t in seconds from the take start
// Both videos of a take are trimmed to the same window, so they line up.
//
// Prerequisites (see ../README.md): emulator running, app built and seeded
// (scripts/build.sh, scripts/seed-device.sh), backoffice running
// (node backoffice/server.mjs).
//
//   node record-takes.mjs [--out DIR] [--rate-mbps 32] [--only 01-audit,02-sync-start]
import { chromium } from 'playwright';
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith('--')) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith('--') ? all[i + 1] : true]);
  return acc;
}, []));

const HOME = os.homedir();
const OUT = path.resolve(args.out || path.join(os.tmpdir(), 'fieldaudit-takes'));
const RATE_MBPS = Number(args['rate-mbps'] ?? 32);
const BACKOFFICE = args.backoffice || 'http://127.0.0.1:8791';
const APP_ID = 'com.hfps.fieldaudit';
const ADB = path.join(process.env.ANDROID_HOME || path.join(HOME, 'Library/Android/sdk'), 'platform-tools/adb');
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'fieldaudit-takes-'));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => Date.now() / 1000;
const log = (...m) => console.log(new Date().toISOString().slice(11, 19), ...m);

function adb(...a) {
  return execFileSync(ADB, a, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}
const shell = (cmd) => adb('shell', cmd);
const tap = (x, y) => shell(`input tap ${x} ${y}`);
const swipe = (x1, y1, x2, y2, ms = 450) => shell(`input swipe ${x1} ${y1} ${x2} ${y2} ${ms}`);
const key = (k) => shell(`input keyevent ${k}`);

async function api(p, method = 'GET') {
  const r = await fetch(BACKOFFICE + p, { method });
  return r.json();
}
const received = async () => (await api('/api/state')).received.photos;

async function waitFor(fn, timeoutMs, everyMs = 300) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (await fn()) return true;
    await sleep(everyMs);
  }
  return false;
}

// ---------------------------------------------------------------- phone ---
class PhoneRecorder {
  async start(name) {
    this.remote = `/sdcard/fa_${name}.mp4`;
    shell(`rm -f ${this.remote}`);
    this.proc = spawn(ADB, ['shell', `screenrecord --bit-rate 16000000 ${this.remote}`], { stdio: 'ignore' });
    // The muxer writes the file once the first frame is encoded.
    await waitFor(() => {
      try { return Number(shell(`stat -c %s ${this.remote} 2>/dev/null || echo 0`)) > 0; } catch { return false; }
    }, 10000, 40);
    this.t0 = now();
  }
  async stop() {
    this.t1 = now();
    const exited = new Promise((r) => this.proc.on('exit', r));
    shell('pkill -2 screenrecord');
    await Promise.race([exited, sleep(8000)]);
    await sleep(500);
    this.local = path.join(TMP, path.basename(this.remote));
    adb('pull', this.remote, this.local);
    shell(`rm -f ${this.remote}`);
    return this;
  }
}

// ----------------------------------------------------------- backoffice ---
class PageRecorder {
  constructor(page) { this.page = page; }
  async start(name) {
    this.dir = path.join(TMP, `bo_${name}`);
    fs.mkdirSync(this.dir, { recursive: true });
    this.frames = [];
    this.cdp = await this.page.context().newCDPSession(this.page);
    // Seed with a frame at t0 so a static page still has a first frame.
    const shot = await this.cdp.send('Page.captureScreenshot', { format: 'jpeg', quality: 92 });
    this.t0 = now();
    this.addFrame(Buffer.from(shot.data, 'base64'), this.t0);
    this.cdp.on('Page.screencastFrame', async (f) => {
      this.addFrame(Buffer.from(f.data, 'base64'), f.metadata.timestamp ?? now());
      try { await this.cdp.send('Page.screencastFrameAck', { sessionId: f.sessionId }); } catch { /* closed */ }
    });
    await this.cdp.send('Page.startScreencast', { format: 'jpeg', quality: 92, maxWidth: 1440, maxHeight: 900, everyNthFrame: 1 });
  }
  addFrame(buf, ts) {
    const file = path.join(this.dir, `f${String(this.frames.length).padStart(6, '0')}.jpg`);
    fs.writeFileSync(file, buf);
    this.frames.push({ file, ts });
  }
  async stop() {
    // Capture a last frame so the take ends on the current state.
    const shot = await this.cdp.send('Page.captureScreenshot', { format: 'jpeg', quality: 92 });
    this.t1 = now();
    this.addFrame(Buffer.from(shot.data, 'base64'), this.t1);
    await this.cdp.send('Page.stopScreencast');
    await this.cdp.detach();
    return this;
  }
}

// ------------------------------------------------------------ assembling ---
function ffmpeg(a) {
  execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...a], { stdio: 'inherit' });
}
function duration(file) {
  return Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file], { encoding: 'utf8' }).trim());
}

function assemble(take, phone, page, events) {
  const dir = path.join(OUT, take.id);
  fs.mkdirSync(dir, { recursive: true });
  const ts = Math.max(phone.t0, page.t0);
  const te = Math.min(phone.t1, page.t1);
  const D = +(te - ts).toFixed(3);

  // Phone: black out the stretches where the display was off; screenrecord
  // produces no frames then, and a frozen last frame would misrepresent it.
  const off = [];
  let offAt = null;
  for (const e of events) {
    if (e.screen === 'off') offAt = e.abs;
    if (e.screen === 'on' && offAt !== null) { off.push([offAt, e.abs]); offAt = null; }
  }
  if (offAt !== null) off.push([offAt, te]);
  const boxes = off.map(([a, b]) => `drawbox=x=0:y=0:w=iw:h=ih:color=black:t=fill:enable='between(t,${(a - ts).toFixed(2)},${(b - ts).toFixed(2)})'`);
  // screenrecord only emits frames when the screen changes, so the file can
  // end before the take does: hold the last frame to the full length.
  const vf = ['tpad=stop_mode=clone:stop_duration=30', 'fps=30', ...boxes].join(',');
  ffmpeg(['-ss', (ts - phone.t0).toFixed(3), '-i', phone.local, '-t', String(D), '-vf', vf, '-an',
    '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', path.join(dir, 'phone.mp4')]);

  // Backoffice: variable-rate screencast frames -> constant 30 fps.
  const frames = page.frames.filter((f) => f.ts <= te).sort((a, b) => a.ts - b.ts);
  let firstIdx = frames.findIndex((f) => f.ts >= ts);
  if (firstIdx === -1) firstIdx = frames.length;
  const list = [];
  const startFrame = frames[Math.max(0, firstIdx - 1)];
  const seq = [{ ...startFrame, ts }, ...frames.slice(firstIdx).filter((f) => f.ts > ts)];
  for (let i = 0; i < seq.length; i++) {
    const next = i + 1 < seq.length ? seq[i + 1].ts : te;
    list.push(`file '${seq[i].file}'`, `duration ${Math.max(0.001, next - seq[i].ts).toFixed(4)}`);
  }
  list.push(`file '${seq[seq.length - 1].file}'`);
  const listFile = path.join(page.dir, 'list.txt');
  fs.writeFileSync(listFile, list.join('\n'));
  ffmpeg(['-f', 'concat', '-safe', '0', '-i', listFile, '-vf', 'fps=30,scale=1440:900:flags=lanczos', '-t', String(D),
    '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', path.join(dir, 'backoffice.mp4')]);

  const out = events.filter((e) => e.abs >= ts - 0.5 && e.abs <= te + 0.5)
    .map((e) => ({ t: +Math.max(0, e.abs - ts).toFixed(2), event: e.event, ...(e.data ? { data: e.data } : {}) }));
  fs.writeFileSync(path.join(dir, 'events.json'), JSON.stringify(out, null, 2) + '\n');
  const dp = duration(path.join(dir, 'phone.mp4'));
  const db = duration(path.join(dir, 'backoffice.mp4'));
  log(`${take.id}: phone ${dp.toFixed(2)} s, backoffice ${db.toFixed(2)} s, ${out.length} events`);
  return { id: take.id, phone: dp, backoffice: db, events: out.length };
}

// ----------------------------------------------------------------- takes ---
// Coordinates are for the 1080x2400 "Medium Phone" AVD.
const UI = {
  auditCard: [540, 1130],
  syncButton: [540, 2227],
  photosTab: [330, 910],
  findingsTab: [130, 910],
};

function makeTakes(ev) {
  return [
    {
      id: '01-audit',
      async run() {
        await sleep(2500);
        tap(...UI.auditCard); ev('open audit AUD-2026-0418');
        await sleep(3500);
        swipe(540, 1900, 540, 900, 700); ev('scroll findings');
        await sleep(2200);
        swipe(540, 1900, 540, 900, 700);
        await sleep(2500);
        swipe(540, 700, 540, 2000, 500); await sleep(400);
        swipe(540, 700, 540, 2000, 500); await sleep(1200);
        tap(...UI.photosTab); ev('photos tab, 336 photos');
        await sleep(2500);
        swipe(540, 1900, 540, 700, 900); await sleep(1800);
        swipe(540, 1900, 540, 700, 900); await sleep(2200);
        swipe(540, 700, 540, 2100, 400); await sleep(300);
        swipe(540, 700, 540, 2100, 400); await sleep(300);
        swipe(540, 700, 540, 2100, 400); await sleep(1000);
        tap(...UI.findingsTab); ev('findings tab');
        await sleep(2500);
      },
    },
    {
      id: '02-sync-start',
      async run() {
        await sleep(2000);
        const before = await received();
        tap(...UI.syncButton); ev('tap Sync');
        const ok = await waitFor(async () => (await received()) > before, 30000, 200);
        if (ok) ev('first photo on the server');
        await sleep(16000);
        ev('photos on the server', { count: await received() });
      },
    },
    {
      id: '03-background',
      async run() {
        await sleep(2000);
        key('KEYCODE_HOME'); ev('home, app in background');
        await sleep(4000);
        shell('cmd statusbar expand-notifications'); ev('notification shade');
        await sleep(6000);
        shell('cmd statusbar collapse');
        await sleep(1500);
        key('KEYCODE_APP_SWITCH'); ev('recents');
        await sleep(2500);
        swipe(540, 1300, 540, 150, 250); ev('app swiped away from recents');
        await sleep(2000);
        key('KEYCODE_HOME');
        await sleep(2000);
        ev('photos on the server', { count: await received() });
        key('KEYCODE_POWER'); ev('screen locked', null, 'off');
        await sleep(14000);
        key('KEYCODE_WAKEUP'); ev('screen on, lock screen', null, 'on');
        await sleep(7000);
        ev('photos on the server', { count: await received() });
      },
    },
    {
      id: '04-offline',
      async run() {
        await sleep(1500);
        swipe(540, 2000, 540, 700, 300); ev('unlock');
        await sleep(800);
        try { shell('wm dismiss-keyguard'); } catch { /* already unlocked */ }
        await sleep(1500);
        shell(`am start -n ${APP_ID}/.MainActivity`); ev('app reopened');
        await sleep(4000);
        tap(...UI.auditCard); await sleep(2500);
        tap(...UI.syncButton); ev('sync screen');
        await sleep(4000);
        shell('cmd connectivity airplane-mode enable'); ev('airplane mode on');
        ev('photos on the server', { count: await received() });
        await sleep(16000);
        const before = await received();
        shell('cmd connectivity airplane-mode disable'); ev('airplane mode off');
        const t0 = now();
        const ok = await waitFor(async () => (await received()) > before, 120000, 250);
        if (ok) ev('queue resumed, next photo on the server', { secondsAfterReconnect: +(now() - t0).toFixed(1) });
        await sleep(12000);
        ev('photos on the server', { count: await received() });
      },
    },
    {
      id: '05-done',
      async run() {
        await sleep(1500);
        const state = await api('/api/audit');
        await waitFor(async () => (await received()) >= state.photoCount, 600000, 500);
        ev('all photos on the server', { count: await received() });
        await sleep(6000);
        key('KEYCODE_BACK'); ev('back to audit');
        await sleep(2500);
        tap(...UI.photosTab); ev('photos tab, all synced');
        await sleep(2500);
        swipe(540, 1900, 540, 700, 900); await sleep(2000);
        swipe(540, 1900, 540, 700, 900); await sleep(2500);
      },
    },
  ];
}

// Tap the shade's "Clear all" button, wherever the current layout puts it.
function clearAllNotifications() {
  try {
    shell('uiautomator dump /sdcard/fa_ui.xml');
    const xml = shell('cat /sdcard/fa_ui.xml');
    const m = xml.match(/text="Clear all"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
    if (m) tap((+m[1] + +m[3]) >> 1, (+m[2] + +m[4]) >> 1);
    else log('No "Clear all" button in the shade');
  } catch (e) {
    log('Could not clear notifications:', e.message);
  }
}

// ------------------------------------------------------------------ main ---
async function prepare(page) {
  log('Preparing device and backoffice');
  shell('cmd connectivity airplane-mode disable');
  shell(`am force-stop ${APP_ID}`);
  shell(`run-as ${APP_ID} rm -rf databases shared_prefs no_backup app_webview/Default/Local\\ Storage`);
  // A swipe lock screen that shows the (silent) sync notification.
  shell('locksettings set-disabled false');
  shell('settings put secure lock_screen_show_silent_notifications 1');
  shell('settings put secure lock_screen_notification_minimalism 0');
  shell('settings put system screen_off_timeout 1800000');
  shell(`pm grant ${APP_ID} android.permission.POST_NOTIFICATIONS`);
  key('KEYCODE_WAKEUP');
  try { shell('wm dismiss-keyguard'); } catch { /* not locked */ }
  // Empty the recents list and the notification shade.
  key('KEYCODE_HOME'); await sleep(800);
  key('KEYCODE_APP_SWITCH'); await sleep(1500);
  for (let i = 0; i < 4; i++) { swipe(540, 1300, 540, 150, 200); await sleep(700); }
  key('KEYCODE_HOME'); await sleep(800);
  shell('cmd statusbar expand-notifications'); await sleep(1500);
  clearAllNotifications();
  await sleep(800);
  shell('cmd statusbar collapse'); await sleep(500);

  await api('/api/reset', 'POST');
  await api(`/api/rate?mbps=${RATE_MBPS}`, 'POST');
  await page.goto(BACKOFFICE + '/');
  await page.waitForTimeout(1500);

  shell(`am start -n ${APP_ID}/.MainActivity`);
  await sleep(5000);
}

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch();
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });
  const page = await context.newPage();
  await prepare(page);

  let events = [];
  const ev = (event, data = null, screen = null) => {
    events.push({ abs: now(), event, data, screen });
    log('  event:', event, data ? JSON.stringify(data) : '');
  };
  const only = args.only ? String(args.only).split(',') : null;
  const results = [];
  for (const take of makeTakes(ev)) {
    const record = !only || only.includes(take.id);
    log(`Take ${take.id}${record ? '' : ' (not recorded)'}`);
    events = [];
    const phone = new PhoneRecorder();
    const rec = new PageRecorder(page);
    if (record) await Promise.all([phone.start(take.id), rec.start(take.id)]);
    ev('take start');
    await take.run();
    ev('take end');
    if (record) {
      await Promise.all([phone.stop(), rec.stop()]);
      results.push(assemble(take, phone, rec, events));
    }
  }
  await browser.close();
  fs.writeFileSync(path.join(OUT, 'takes.json'), JSON.stringify({ recordedAt: new Date().toISOString(), rateMbps: RATE_MBPS, takes: results }, null, 2) + '\n');
  fs.rmSync(TMP, { recursive: true, force: true });
  log('Done:', OUT);
}

main().catch((e) => { console.error(e); process.exit(1); });

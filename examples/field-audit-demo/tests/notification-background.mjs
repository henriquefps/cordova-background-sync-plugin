// Progress notification while the app is in the background.
//
// Full audit sync; once some photos are on the server the app goes Home, then
// airplane mode is switched on and off while the app stays in the background,
// so WorkManager stops the worker and starts it again from the background
// (where Android 12+ refuses to start a foreground service). Every few seconds
// the script samples the server count and the app's notifications.
//
//   node notification-background.mjs [--label after] [--rate 32] [--offline-ms 10000]
//
// Pass: the notification keeps advancing while uploads continue, the final
// notification is the success one, and no ongoing notification is left.
import * as t from './lib.mjs';

const arg = (name, def) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : def;
};
const label = arg('label', 'run');
const rate = Number(arg('rate', 32));
const offlineMs = Number(arg('offline-ms', 10000));

t.resetApp();
await t.boReset();
await t.clearFaults();
await t.setRate(rate);
t.grantNotifications(true);
t.logcatClear();
t.launchApp();
await t.connect();
await t.initialize();
const base = await t.filesDir();
const photos = t.auditPhotos();
await t.enqueuePhotos(photos, base);
await t.plugin('enqueueSync');
t.log(`Queued ${photos.length} photos, sync started (ingest cap ${rate} Mbit/s)`);

const timeline = [];
const t0 = Date.now();
async function sample(note = '') {
  const s = await t.boState();
  const n = t.notifications().filter((x) => x.id !== undefined);
  const main = n.map((x) => `${x.id}${x.ongoing ? '*' : ''}${x.fgs ? 'F' : ''}:${x.title}|${x.text}`).join(' ; ');
  const row = { s: Math.round((Date.now() - t0) / 1000), server: s.received.photos, notifications: n, note };
  timeline.push(row);
  t.log(`${String(row.s).padStart(4)}s server=${String(s.received.photos).padStart(3)} ${note ? `[${note}] ` : ''}${main}`);
  return s.received.photos;
}

await t.waitFor(async () => (await sample()) >= 15, { timeout: 120000, interval: 3000, what: '15 photos on the server' });
t.disconnect();
t.home();
await sample('home');
await t.sleep(10000);
await sample();
t.setAirplane(true);
await sample('airplane on');
await t.sleep(offlineMs);
t.setAirplane(false);
await sample('airplane off');

let done = false;
const until = Date.now() + 15 * 60 * 1000;
while (Date.now() < until) {
  await t.sleep(5000);
  const n = await sample();
  if (n >= photos.length) {
    // Let the worker post its final notification.
    await t.sleep(5000);
    await sample('final');
    done = true;
    break;
  }
}

// Freeze detection: the notification text did not change between two samples
// 20 s or more apart while the server received 10 or more photos.
const progressText = (row) => (row.notifications.find((x) => x.ongoing) || {}).text || null;
let frozen = null;
for (let i = 0; i < timeline.length; i++) {
  for (let j = i + 1; j < timeline.length; j++) {
    const a = timeline[i];
    const b = timeline[j];
    if (b.s - a.s < 20) continue;
    if (progressText(a) && progressText(a) === progressText(b) && b.server - a.server >= 10) {
      const slice = timeline.slice(i, j + 1);
      if (slice.every((r) => progressText(r) === progressText(a))) {
        if (!frozen || b.s - a.s > frozen.seconds) frozen = { text: progressText(a), from: a.s, to: b.s, seconds: b.s - a.s, serverFrom: a.server, serverTo: b.server };
      }
    }
  }
}
const final = timeline[timeline.length - 1].notifications;
const leftOngoing = final.filter((x) => x.ongoing);
const fs = await import('node:fs');
const path = await import('node:path');
fs.writeFileSync(path.join(t.OUT_DIR, `notification-${label}-timeline.json`), JSON.stringify({ frozen, timeline }, null, 2));
fs.writeFileSync(path.join(t.OUT_DIR, `notification-${label}-logcat.txt`), t.logcat());
fs.writeFileSync(path.join(t.OUT_DIR, `notification-${label}-dumpsys.txt`), t.shell('dumpsys notification --noredact'));
t.screen(true);
t.shell('cmd statusbar expand-notifications');
await t.sleep(1500);
t.screenshot(`notification-${label}-final-shade`);
t.shell('cmd statusbar collapse');

t.log(`Done: ${done}. Frozen: ${frozen ? JSON.stringify(frozen) : 'no'}. Ongoing left: ${leftOngoing.length}. Final: ${final.map((x) => `${x.id}:${x.title}|${x.text}`).join(' ; ')}`);
t.log(`Artifacts in ${t.OUT_DIR}`);
await t.setRate(0);
process.exit(done && !frozen && leftOngoing.length === 0 ? 0 : 1);

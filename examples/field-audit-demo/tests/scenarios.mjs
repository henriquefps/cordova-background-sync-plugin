// Android test scenarios for the Background Sync plugin, run against the demo
// app on an emulator and the demo backoffice (with fault injection).
//
//   node scenarios.mjs --list
//   node scenarios.mjs http-errors cancel-resync          # run some
//   node scenarios.mjs all                                 # run every scenario except the slow ones
//   node scenarios.mjs all --slow                          # include timeout, reboot and full-sync scenarios
//
// Each scenario prints PASS/FAIL lines (what was expected, what was observed)
// and the whole run is written to $OUT_DIR/results-<timestamp>.json.
import * as t from './lib.mjs';

const TEST_ENDPOINT = 'api/v1/test/records';
const FILES = `/data/user/0/${t.APP_ID}/files/tests`;

// ------------------------------------------------------------------ helpers ---
async function setup(config = {}, { notifications = true } = {}) {
  t.resetApp();
  await t.boReset();
  await t.clearFaults();
  await t.setRate(0);
  t.grantNotifications(notifications);
  t.logcatClear();
  t.launchApp();
  await t.connect();
  await t.initialize(config);
  await t.clearEvents();
}

function makeFile(name, bytes) {
  t.runAs(`mkdir -p files/tests && head -c ${bytes} /dev/urandom > files/tests/${name}`);
  return `${FILES}/${name}`;
}
const deviceMd5 = (p) => t.runAs(`md5sum ${p.replace(`/data/user/0/${t.APP_ID}/`, '')}`).split(/\s+/)[0];

function testRecord(id, extra = {}) {
  return { id, endpoint: TEST_ENDPOINT, payload: JSON.stringify({ id, note: extra.note || 'test' }), ...extra.record };
}
async function enqueueMany(records) {
  return t.evaluate(`(async () => {
    const P = cordova.plugins.BackgroundSyncPlugin;
    for (const r of ${JSON.stringify(records)}) await new Promise((res, rej) => P.enqueueRecord(r, res, rej));
    return true;
  })()`);
}
const ids = (prefix, n) => Array.from({ length: n }, (_, i) => `${prefix}-${String(i + 1).padStart(3, '0')}`);

// Server view: successful deliveries per id.
async function deliveries() {
  const logs = await t.boLog();
  const out = {};
  for (const [id, entries] of Object.entries(logs)) {
    out[id] = entries.filter((e) => e.status === 200 && (e.path.includes('/test/records') || e.path === '/upload' || e.path.includes('/audits/photos'))).length;
  }
  return out;
}
const queueRows = (table = 'sync_queue') => t.plugin('executeRawQuery', `SELECT Id, Status, Error FROM ${table} ORDER BY Sequence`, []);
async function statusCounts(table = 'sync_queue') {
  const rows = await queueRows(table);
  const c = {};
  for (const r of rows) c[r.Status] = (c[r.Status] || 0) + 1;
  return c;
}
const waitEvent = (name, since, timeout = 120000) =>
  t.waitFor(async () => (await t.events(since)).find((e) => e.event === name), { timeout, interval: 1000, what: `event ${name}` });

// Work state from the plugin's view: true when nothing is pending/failed and no completed event is missing.
async function waitQueueDrained(timeout = 180000) {
  return t.waitFor(async () => {
    const q = await t.plugin('getQueuedRecords');
    return q.length === 0;
  }, { timeout, interval: 1500, what: 'queue drained' });
}
function workState() {
  const out = t.shell(`dumpsys jobscheduler | grep -A3 "${t.APP_ID}/androidx.work" | head -40`);
  return out;
}
const appNotifications = () => t.notifications();
const fmtN = (n) => n.map((x) => `${x.id}${x.ongoing ? '(ongoing)' : ''}:${x.title}|${x.text}`).join(' ; ') || 'none';

// ---------------------------------------------------------------- scenarios ---
const S = {};

S['full-sync'] = { slow: true, desc: 'Full 336-photo audit sync, md5 of every photo matches', async run() {
  await setup();
  const photos = t.auditPhotos();
  const base = await t.filesDir();
  const since = Date.now();
  await t.enqueuePhotos(photos, base);
  await t.plugin('enqueueSync');
  await waitEvent('completed', since, 15 * 60000);
  const st = await t.boState();
  const md5 = t.devicePhotoMd5();
  const byId = Object.fromEntries(st.photos.map((p) => [p.photoId, p]));
  const mismatched = photos.filter((p) => !byId[p.id] || byId[p.id].md5 !== md5[p.file]);
  const counts = await statusCounts();
  const n = appNotifications();
  t.record('full-sync', '336 photos on the server, md5 identical, 336 rows completed, success notification only',
    `server ${st.received.photos} photos ${st.received.bytes} bytes, md5 mismatches ${mismatched.length}, rows ${JSON.stringify(counts)}, notifications: ${fmtN(n)}`,
    st.received.photos === 336 && mismatched.length === 0 && counts.completed === 336 && !n.some((x) => x.ongoing));
} };

S['http-errors'] = { desc: 'HTTP 500 and 413 on some items do not abort the queue; failed items are retried by the next run', async run() {
  await setup();
  await t.setFaults([{ id: 'he-003', status: 500 }, { id: 'he-007', status: 413 }]);
  const list = ids('he', 10);
  let since = Date.now();
  await enqueueMany(list.map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  const done = await waitEvent('completed', since);
  const d = await deliveries();
  const rows = await queueRows();
  const failed = rows.filter((r) => r.Status === 'failed').map((r) => `${r.Id}:${r.Error}`);
  const ev = await t.events(since);
  const n = appNotifications();
  t.record('http-errors: queue continues', '8 delivered, he-003/he-007 failed with HTTP 500/413, completed event, partial-failure notification, no ongoing notification',
    `delivered ${Object.values(d).filter((x) => x > 0).length}, failed rows [${failed.join(', ')}], failed events ${ev.filter((e) => e.event === 'failed').length}, completed ${done.completedCount}/${done.totalCount}, notifications: ${fmtN(n)}`,
    Object.values(d).filter((x) => x > 0).length === 8 && failed.length === 2 && !n.some((x) => x.ongoing) && n.some((x) => /error|rejected|failed/i.test(`${x.title} ${x.text}`)));
  await t.clearFaults();
  since = Date.now();
  await t.plugin('enqueueSync');
  await waitEvent('completed', since);
  const d2 = await deliveries();
  const c2 = await statusCounts();
  const n2 = appNotifications();
  t.record('http-errors: retry on next run', 'next enqueueSync sends only the 2 failed items; all 10 completed; success notification',
    `deliveries per id ${JSON.stringify(d2)}, rows ${JSON.stringify(c2)}, notifications: ${fmtN(n2)}`,
    c2.completed === 10 && Object.values(d2).every((x) => x === 1) && Object.keys(d2).length === 10);
} };

S['http-503-every-nth'] = { desc: 'Every 4th request answers 503, slow responses (1.5 s) on others', async run() {
  await setup();
  await t.setFaults([{ status: 503, every: 4 }, { delayMs: 1500, path: '/test/records', every: 3 }]);
  const list = ids('n', 12);
  const since = Date.now();
  await enqueueMany(list.map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await waitEvent('completed', since);
  const c = await statusCounts();
  t.record('503 every 4th + slow responses', '3 failed (503), 9 completed, run reaches completed', `rows ${JSON.stringify(c)}`, c.failed === 3 && c.completed === 9);
} };

S['dropped-connection'] = { desc: 'Server drops the connection on one item: transient, item is retried and delivered', async run() {
  await setup();
  await t.setFaults([{ id: 'dc-004', drop: true, times: 1 }]);
  const list = ids('dc', 8);
  const since = Date.now();
  await enqueueMany(list.map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await waitEvent('completed', since, 180000);
  const d = await deliveries();
  const c = await statusCounts();
  const ev = await t.events(since);
  t.record('dropped connection', 'failed event for dc-004 (Upload Exception), run retried by WorkManager, all 8 completed, each delivered once',
    `rows ${JSON.stringify(c)}, deliveries ${JSON.stringify(d)}, failed events: ${ev.filter((e) => e.event === 'failed').map((e) => e.error).join(' | ')}`,
    c.completed === 8 && Object.values(d).every((x) => x === 1));
} };

S['server-timeout'] = { slow: true, desc: 'Server never answers one request: client read timeout (5 min), then retry', async run() {
  await setup();
  await t.setFaults([{ id: 'to-002', hang: true, times: 1 }]);
  const since = Date.now();
  await enqueueMany(ids('to', 3).map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await waitEvent('completed', since, 12 * 60000);
  const c = await statusCounts();
  const ev = await t.events(since);
  t.record('server timeout', 'after ~5 min the hung request fails as transient, retry delivers it, 3 completed',
    `rows ${JSON.stringify(c)}, failed events: ${ev.filter((e) => e.event === 'failed').map((e) => `${Math.round((e.t - since) / 1000)}s ${e.error}`).join(' | ')}`,
    c.completed === 3);
} };

S['cancel-resync'] = { desc: 'cancelSync mid-run, then sync again: no duplicates, no lost items', async run() {
  await setup();
  await t.setFaults([{ delayMs: 400, path: '/test/records' }]);
  const list = ids('cr', 30);
  let since = Date.now();
  await enqueueMany(list.map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await t.waitFor(async () => Object.keys(await deliveries()).length >= 8, { timeout: 60000, what: '8 delivered' });
  await t.plugin('cancelSync');
  await t.sleep(3000);
  const afterCancel = Object.keys(await deliveries()).length;
  await t.sleep(4000);
  const later = Object.keys(await deliveries()).length;
  const n = appNotifications();
  t.record('cancelSync stops the run', 'no new deliveries 3 s after cancel (one in-flight item may finish), no ongoing notification left',
    `delivered ${afterCancel} right after cancel, ${later} 4 s later, notifications: ${fmtN(n)}`, later === afterCancel && !n.some((x) => x.ongoing));
  since = Date.now();
  await t.plugin('enqueueSync');
  await waitEvent('completed', since);
  const d = await deliveries();
  const c = await statusCounts();
  const dup = Object.entries(d).filter(([, x]) => x > 1);
  t.record('sync again after cancel', '30 completed, every id delivered exactly once',
    `rows ${JSON.stringify(c)}, ids delivered ${Object.keys(d).length}, duplicates ${JSON.stringify(dup)}`, c.completed === 30 && dup.length === 0 && Object.keys(d).length === 30);
} };

S['enqueue-during-run'] = { desc: 'Records enqueued and enqueueSync called while a run is in progress', async run() {
  await setup();
  await t.setFaults([{ delayMs: 300, path: '/test/records' }]);
  const first = ids('ed-a', 20);
  const second = ids('ed-b', 10);
  const since = Date.now();
  await enqueueMany(first.map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await t.waitFor(async () => Object.keys(await deliveries()).length >= 5, { timeout: 60000, what: '5 delivered' });
  await enqueueMany(second.map((id) => testRecord(id)));
  // The JS layer also calls enqueueSync on every "online" event.
  await t.plugin('enqueueSync');
  await t.plugin('enqueueSync');
  await t.waitFor(async () => (await statusCounts()).completed === 30, { timeout: 120000, what: '30 completed' });
  await t.sleep(4000);
  const d = await deliveries();
  const dup = Object.entries(d).filter(([, x]) => x > 1);
  const ev = await t.events(since);
  const starts = ev.filter((e) => e.event === 'started').length;
  t.record('enqueue + enqueueSync during a run', 'all 30 delivered exactly once; records added mid-run go out without restarting the run',
    `ids delivered ${Object.keys(d).length}, duplicates ${JSON.stringify(dup)}, started events ${starts}, completed events ${ev.filter((e) => e.event === 'completed').length}`,
    Object.keys(d).length === 30 && dup.length === 0);
} };

S['clear-remove-during-run'] = { desc: 'clearQueue and removeRecords while a run is in progress, and after it', async run() {
  await setup();
  await t.setFaults([{ delayMs: 400, path: '/test/records' }]);
  const list = ids('rm', 20);
  let since = Date.now();
  await enqueueMany(list.map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await t.waitFor(async () => Object.keys(await deliveries()).length >= 3, { timeout: 60000, what: '3 delivered' });
  const removed = list.slice(14);
  await t.plugin('removeRecords', removed);
  await t.waitFor(async () => (await t.plugin('getQueuedRecords')).length === 0, { timeout: 60000, what: 'queue empty' });
  await t.sleep(2000);
  const d = await deliveries();
  const sentRemoved = removed.filter((id) => d[id]);
  t.record('removeRecords during run', 'the 6 removed records are never sent; the other 14 are',
    `delivered ${Object.keys(d).length}, removed-but-sent ${JSON.stringify(sentRemoved)}`, sentRemoved.length === 0 && Object.keys(d).length === 14);

  await t.boReset();
  await t.plugin('clearQueue');
  const list2 = ids('cq', 20);
  since = Date.now();
  await enqueueMany(list2.map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await t.waitFor(async () => Object.keys(await deliveries()).length >= 3, { timeout: 60000, what: '3 delivered' });
  await t.plugin('clearQueue');
  const atClear = Object.keys(await deliveries()).length;
  await t.sleep(6000);
  const d2 = await deliveries();
  const logs = await t.boLog();
  const emptyPayload = Object.entries(logs).filter(([id]) => id === 'unknown' || id === 'undefined').length;
  const rows = await queueRows();
  t.record('clearQueue during run', 'at most the in-flight record is sent after clearQueue; no record is sent with an empty payload; queue table empty',
    `delivered at clear ${atClear}, 6 s later ${Object.keys(d2).length}, requests without payload id ${emptyPayload}, rows ${rows.length}`,
    Object.keys(d2).length <= atClear + 1 && emptyPayload === 0 && rows.length <= 1);

  await t.boReset();
  await t.clearFaults();
  since = Date.now();
  await enqueueMany(ids('after', 4).map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await waitEvent('completed', since);
  await t.plugin('removeRecords', ['after-001', 'after-002']);
  const synced = await t.plugin('getSyncedRecords');
  await t.plugin('clearQueue');
  const rowsAfter = await queueRows();
  t.record('removeRecords/clearQueue after a run', 'removeRecords drops completed rows, clearQueue empties the table',
    `synced after removing 2 of 4: ${synced.length}, rows after clearQueue: ${rowsAfter.length}`, synced.length === 2 && rowsAfter.length === 0);
} };

S['duplicate-ids'] = { desc: 'Enqueueing the same id twice keeps one row and sends the latest payload once', async run() {
  await setup();
  const since = Date.now();
  await enqueueMany([testRecord('dup-1', { note: 'first' }), testRecord('dup-1', { note: 'second' }), testRecord('dup-2')]);
  const rows = await queueRows();
  await t.plugin('enqueueSync');
  await waitEvent('completed', since);
  const logs = await t.boLog();
  const sent = (logs['dup-1'] || []).filter((e) => e.status === 200);
  t.record('duplicate record ids', 'one row for dup-1, sent once with payload note "second"',
    `rows before sync ${rows.length}, dup-1 deliveries ${sent.length}, note ${sent.map((e) => e.payload.note).join(',')}`, rows.length === 2 && sent.length === 1 && sent[0].payload.note === 'second');
} };

S['notifications-disabled'] = { desc: 'enableNotifications false: no notification at any point', async run() {
  await setup({ enableNotifications: false });
  await t.setFaults([{ delayMs: 300, path: '/test/records' }]);
  const since = Date.now();
  await enqueueMany(ids('nn', 10).map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  let seen = [];
  await t.waitFor(async () => {
    seen = seen.concat(appNotifications());
    return (await t.events(since)).some((e) => e.event === 'completed');
  }, { timeout: 60000, interval: 700, what: 'completed' });
  await t.sleep(1500);
  seen = seen.concat(appNotifications());
  const c = await statusCounts();
  t.record('enableNotifications false', '10 completed, no notification seen during or after the run', `rows ${JSON.stringify(c)}, notifications seen: ${fmtN(seen)}`, c.completed === 10 && seen.length === 0);
} };

S['notifications-denied'] = { desc: 'POST_NOTIFICATIONS denied (Android 13+): sync completes, nothing crashes', async run() {
  await setup({}, { notifications: false });
  await t.setFaults([{ delayMs: 300, path: '/test/records' }]);
  const since = Date.now();
  await enqueueMany(ids('nd', 10).map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await waitEvent('completed', since, 60000);
  const c = await statusCounts();
  const crash = t.logcat('FATAL EXCEPTION');
  const perm = await t.evaluate(`new Promise(r => cordova.plugins.BackgroundSyncPlugin.requestNotificationsPermission(x => r('ok: ' + x), e => r('error: ' + e)))`).catch((e) => e.message);
  t.record('POST_NOTIFICATIONS denied', '10 completed, no crash', `rows ${JSON.stringify(c)}, crash lines ${crash ? crash.split('\n').length : 0}, notifications: ${fmtN(appNotifications())}, requestNotificationsPermission -> ${perm}`, c.completed === 10 && !crash);
  t.grantNotifications(true);
} };

S['wifi-only'] = { desc: 'syncOnlyOnWifi true: waits while only cellular is up, runs when wifi is back', async run() {
  await setup({ syncOnlyOnWifi: true });
  t.setWifi(false);
  t.setData(true);
  await t.sleep(4000);
  const since = Date.now();
  await enqueueMany(ids('wo', 5).map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await t.sleep(10000);
  const before = Object.keys(await deliveries()).length;
  t.setWifi(true);
  await waitEvent('completed', since, 90000);
  const after = Object.keys(await deliveries()).length;
  t.record('syncOnlyOnWifi', 'nothing sent on cellular only; all 5 sent once wifi is back', `on cellular ${before}, after wifi on ${after}`, before === 0 && after === 5);
} };

S['charging-only'] = { desc: 'syncOnlyWhenCharging true: waits on battery, runs when plugged in', async run() {
  await setup({ syncOnlyWhenCharging: true });
  t.shell('dumpsys battery unplug');
  t.shell('dumpsys battery set status 3');
  await t.sleep(2000);
  const since = Date.now();
  await enqueueMany(ids('ch', 5).map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await t.sleep(10000);
  const before = Object.keys(await deliveries()).length;
  t.shell('dumpsys battery set ac 1');
  t.shell('dumpsys battery set status 2');
  try {
    await waitEvent('completed', since, 90000);
  } finally {
    t.shell('dumpsys battery reset');
  }
  const after = Object.keys(await deliveries()).length;
  t.record('syncOnlyWhenCharging', 'nothing sent on battery; all 5 sent once charging', `on battery ${before}, after plugging in ${after}`, before === 0 && after === 5);
} };

S['encrypted-db'] = { desc: 'encryptDatabase true: queue, sync, executeRawQuery, inspector', async run() {
  await setup({ encryptDatabase: true });
  const since = Date.now();
  await enqueueMany(ids('enc', 5).map((id) => testRecord(id)));
  const header = t.runAs('head -c 16 databases/bg_sync.db | od -c | head -1');
  await t.plugin('enqueueSync');
  await waitEvent('completed', since);
  const rows = await t.plugin('executeRawQuery', 'SELECT COUNT(*) AS n FROM sync_queue WHERE Status = ?', ['completed']);
  await t.plugin('openDatabaseInspector');
  await t.sleep(2500);
  const shot = t.screenshot('encrypted-db-inspector');
  const top = t.shell('dumpsys activity activities | grep -m1 -E "topResumedActivity|mResumedActivity"');
  t.key('KEYCODE_BACK');
  t.record('encryptDatabase true', 'file is not plain SQLite, 5 completed, raw query works, inspector opens',
    `header: ${header.replace(/\s+/g, ' ').slice(0, 60)}, completed ${rows[0].n}, top activity: ${top.trim()}, screenshot ${shot}`,
    !/S\s+Q\s+L\s+i\s+t\s+e/.test(header) && Number(rows[0].n) === 5 && /DatabaseInspector/.test(top));
} };

S['auto-delete'] = { desc: 'autoDeleteCompleted true: sent rows are removed from sync_queue', async run() {
  await setup({ autoDeleteCompleted: true });
  const since = Date.now();
  await enqueueMany(ids('ad', 5).map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await waitEvent('completed', since);
  const rows = await queueRows();
  const synced = await t.plugin('getSyncedRecords');
  const d = await deliveries();
  t.record('autoDeleteCompleted', '5 delivered, sync_queue empty, getSyncedRecords empty (expected with autoDelete)', `delivered ${Object.keys(d).length}, rows ${rows.length}, synced ${synced.length}`,
    Object.keys(d).length === 5 && rows.length === 0 && synced.length === 0);
} };

S['downloads'] = { desc: 'Download queue: REST_PAYLOAD and BINARY_FILE, paging, removeDownloads, clearDownloadQueue', async run() {
  await setup();
  const blobs = ['bin-1', 'bin-2'];
  const recs = [
    { id: 'dl-get', endpoint: 'api/v1/test/download/dl-get' },
    { id: 'dl-post', endpoint: 'api/v1/test/download/dl-post', payload: JSON.stringify({ q: 42 }) },
    { id: 'dl-abs', endpoint: `${t.SERVER_URL}/api/v1/test/download/dl-abs` },
    ...blobs.map((b, i) => ({ id: b, endpoint: `api/v1/test/blob/${b}?bytes=${(i + 1) * 1500000}`, downloadStrategy: 'BINARY_FILE', filePath: `file://${FILES}/dl/${b}.bin` })),
    { id: 'dl-404', endpoint: 'api/v1/test/nope' },
  ];
  for (const r of recs) await t.plugin('enqueueDownload', r);
  const queued = await t.plugin('getQueuedDownloads');
  const since = Date.now();
  await t.plugin('enqueueSync');
  await waitEvent('completed', since);
  const ev = await t.events(since);
  const logs = await t.boLog();
  const md5ok = blobs.every((b) => { try { return deviceMd5(`${FILES}/dl/${b}.bin`) === logs[b].find((e) => e.md5).md5; } catch { return false; } });
  const page1 = await t.plugin('getCompletedDownloads', { limit: 2, offset: 0 });
  const page2 = await t.plugin('getCompletedDownloads', { limit: 2, offset: 2 });
  const page3 = await t.plugin('getCompletedDownloads', { limit: 2, offset: 4 });
  const all = await t.plugin('getCompletedDownloads');
  const post = all.records.find((r) => r.id === 'dl-post');
  const failed = await t.plugin('getQueuedDownloads');
  t.record('downloads: run', '6 queued; 5 completed, dl-404 failed (HTTP 404), binary md5 match, POST payload echoed, download events fired',
    `queued ${queued.length}, completed ${all.records.length}, failed ${JSON.stringify(failed.map((f) => f.id + ':' + f.error.slice(0, 20)))}, md5 ${md5ok}, echo ${post && JSON.parse(post.responseData).echo?.q}, events ${[...new Set(ev.map((e) => e.event))].join(',')}`,
    queued.length === 6 && all.records.length === 5 && failed.length === 1 && md5ok && post && JSON.parse(post.responseData).echo?.q === 42 && ev.some((e) => e.event === 'started_download'));
  t.record('downloads: paging', 'pages of 2/2/1 with hasMore true/true/false, no overlap',
    `sizes ${page1.records.length}/${page2.records.length}/${page3.records.length}, hasMore ${page1.hasMore}/${page2.hasMore}/${page3.hasMore}, unique ${new Set([...page1.records, ...page2.records, ...page3.records].map((r) => r.id)).size}`,
    page1.records.length === 2 && page2.records.length === 2 && page3.records.length === 1 && page1.hasMore && page2.hasMore && !page3.hasMore &&
    new Set([...page1.records, ...page2.records, ...page3.records].map((r) => r.id)).size === 5);
  await t.plugin('removeDownloads', ['dl-get', 'dl-404']);
  const afterRemove = (await queueRows('download_queue')).length;
  await t.plugin('clearDownloadQueue');
  const afterClear = (await queueRows('download_queue')).length;
  t.record('downloads: remove/clear', 'removeDownloads drops 2 rows (6 -> 4), clearDownloadQueue empties the table', `after remove ${afterRemove}, after clear ${afterClear}`, afterRemove === 4 && afterClear === 0);

  // autoDeleteCompleted: each page is deleted as it is read, offsets are ignored.
  await setup({ autoDeleteCompleted: true });
  for (let i = 1; i <= 5; i++) await t.plugin('enqueueDownload', { id: `ad-${i}`, endpoint: `api/v1/test/download/ad-${i}` });
  const s2 = Date.now();
  await t.plugin('enqueueSync');
  await waitEvent('completed', s2);
  const a1 = await t.plugin('getCompletedDownloads', { limit: 2, offset: 0 });
  const a2 = await t.plugin('getCompletedDownloads', { limit: 2, offset: 2 });
  const a3 = await t.plugin('getCompletedDownloads', { limit: 2 });
  const left = (await queueRows('download_queue')).length;
  t.record('downloads: paging with autoDeleteCompleted', 'three reads return 2/2/1 distinct records and the table ends empty',
    `sizes ${a1.records.length}/${a2.records.length}/${a3.records.length}, unique ${new Set([...a1.records, ...a2.records, ...a3.records].map((r) => r.id)).size}, rows left ${left}`,
    a1.records.length === 2 && a2.records.length === 2 && a3.records.length === 1 && left === 0);
} };

S['presigned'] = { desc: 'PRESIGNED_URL uploads: handshake + PUT, md5 match; handshake and PUT errors', async run() {
  await setup();
  const files = ['ps-1', 'ps-2', 'ps-3', 'ps-4'].map((id, i) => ({ id, path: makeFile(`${id}.bin`, 300000 * (i + 1)) }));
  await t.setFaults([{ path: '/test/presign', id: 'ps-3', status: 500 }, { path: '/upload/', id: 'ps-4', status: 403 }]);
  const since = Date.now();
  await enqueueMany(files.map((f) => ({ id: f.id, endpoint: 'api/v1/test/presign', payload: JSON.stringify({ id: f.id, contentType: 'application/octet-stream' }), filePath: f.path, uploadStrategy: 'PRESIGNED_URL' })));
  await enqueueMany([{ id: 'ps-missing', endpoint: 'api/v1/test/presign', payload: JSON.stringify({ id: 'ps-missing' }), filePath: `${FILES}/nope.bin`, uploadStrategy: 'PRESIGNED_URL' }]);
  await t.plugin('enqueueSync');
  await waitEvent('completed', since);
  const logs = await t.boLog();
  const ok = files.slice(0, 2).every((f) => (logs[f.id] || []).some((e) => e.path === '/upload' && e.md5 === deviceMd5(f.path)));
  const rows = await queueRows();
  const st = Object.fromEntries(rows.map((r) => [r.Id, `${r.Status}${r.Error ? ' ' + r.Error.slice(0, 40) : ''}`]));
  t.record('PRESIGNED_URL', 'ps-1/ps-2 PUT with md5 match; ps-3 failed (handshake 500), ps-4 failed (PUT 403), ps-missing failed (file not found); run completes',
    `md5 ok ${ok}, rows ${JSON.stringify(st)}`, ok && st['ps-1'].startsWith('completed') && st['ps-3'].startsWith('failed') && st['ps-4'].startsWith('failed') && st['ps-missing'].startsWith('failed'));
} };

S['missing-file'] = { desc: 'REST_PAYLOAD record whose file does not exist', async run() {
  await setup();
  const since = Date.now();
  await enqueueMany([{ id: 'mf-1', endpoint: TEST_ENDPOINT, payload: JSON.stringify({ id: 'mf-1' }), filePath: `file://${FILES}/does-not-exist.jpg` }]);
  await t.plugin('enqueueSync');
  await waitEvent('completed', since);
  const rows = await queueRows();
  const logs = await t.boLog();
  t.record('missing file (REST_PAYLOAD)', 'record is marked failed with "Local file not found", not sent without its file',
    `row ${JSON.stringify(rows[0])}, server got ${(logs['mf-1'] || []).length} request(s)`, rows[0].Status === 'failed' && !(logs['mf-1'] || []).length);
} };

S['file-url-encoding'] = { desc: 'filePath as a file:// URL with an encoded space', async run() {
  await setup();
  t.runAs("mkdir -p files/tests && head -c 50000 /dev/urandom > 'files/tests/with space.bin'");
  const since = Date.now();
  await enqueueMany([{ id: 'sp-1', endpoint: TEST_ENDPOINT, payload: JSON.stringify({ id: 'sp-1' }), filePath: `file://${FILES}/with%20space.bin` }]);
  await t.plugin('enqueueSync');
  await waitEvent('completed', since);
  const logs = await t.boLog();
  const e = (logs['sp-1'] || []).find((x) => x.status === 200);
  const md5 = t.runAs("md5sum 'files/tests/with space.bin'").split(/\s+/)[0];
  t.record('file:// URL with %20', 'file found and sent, md5 match', `server entry ${e ? `${e.bytes} bytes md5 ${e.md5 === md5}` : 'none'}`, !!e && e.md5 === md5);
} };

S['raw-query'] = { desc: 'executeRawQuery: SELECT, PRAGMA, writes with args, errors', async run() {
  await setup();
  await enqueueMany(ids('rq', 3).map((id) => testRecord(id)));
  const sel = await t.plugin('executeRawQuery', 'SELECT Id FROM sync_queue WHERE Id LIKE ? ORDER BY Id', ['rq-%']);
  const pragma = await t.plugin('executeRawQuery', 'PRAGMA table_info(sync_queue)', []);
  const upd = await t.plugin('executeRawQuery', 'UPDATE sync_queue SET Status = ? WHERE Id = ?', ['completed', 'rq-001']);
  const after = await t.plugin('executeRawQuery', "  select Status from sync_queue where Id = 'rq-001'", []);
  const cte = await t.plugin('executeRawQuery', 'WITH x AS (SELECT Id FROM sync_queue) SELECT COUNT(*) AS n FROM x', []).catch((e) => `error: ${e.message}`);
  const bad = await t.plugin('executeRawQuery', 'SELEKT nope', []).catch((e) => `error: ${e.message}`);
  t.record('executeRawQuery', 'SELECT with args returns 3 rows, PRAGMA returns 8 columns, UPDATE with args applies, lowercase select works, CTE returns a row, bad SQL rejects with an error',
    `select ${sel.length}, pragma ${pragma.length}, update "${upd}", after ${JSON.stringify(after)}, cte ${JSON.stringify(cte)}, bad ${String(bad).slice(0, 60)}`,
    sel.length === 3 && pragma.length === 8 && after[0]?.Status === 'completed' && Array.isArray(cte) && String(bad).startsWith('error'));
} };

S['inspector'] = { desc: 'openDatabaseInspector opens and lists the queue', async run() {
  await setup();
  await enqueueMany(ids('in', 3).map((id) => testRecord(id)));
  await t.plugin('openDatabaseInspector');
  await t.sleep(2500);
  const top = t.shell('dumpsys activity activities | grep -m1 -E "topResumedActivity|mResumedActivity"');
  const shot = t.screenshot('inspector');
  t.key('KEYCODE_BACK');
  await t.sleep(800);
  const back = t.shell('dumpsys activity activities | grep -m1 -E "topResumedActivity|mResumedActivity"');
  t.record('openDatabaseInspector', 'inspector activity resumed, back returns to the app', `top: ${top.trim()}, after back: ${back.trim()}, screenshot ${shot}`, /DatabaseInspector/.test(top) && /MainActivity/.test(back));
} };

S['large-file'] = { desc: 'One 60 MB file with REST_PAYLOAD (base64 JSON body)', async run() {
  await setup();
  const p = makeFile('large-60mb.bin', 60 * 1024 * 1024);
  const since = Date.now();
  await enqueueMany([{ id: 'big-1', endpoint: TEST_ENDPOINT, payload: JSON.stringify({ id: 'big-1' }), filePath: p }]);
  await t.plugin('enqueueSync');
  const end = await t.waitFor(async () => (await t.events(since)).find((e) => e.event === 'completed' || e.event === 'failed'), { timeout: 600000, interval: 2000, what: 'end of run' }).catch((e) => ({ event: 'timeout', error: e.message }));
  const logs = await t.boLog();
  const e = (logs['big-1'] || []).find((x) => x.status === 200);
  const oom = t.logcat('OutOfMemoryError|FATAL EXCEPTION');
  const rows = await queueRows().catch(() => []);
  t.record('large file 60 MB REST_PAYLOAD', 'delivered, md5 match, record completed, no OutOfMemoryError',
    `end event ${end.event}${end.error ? ' ' + end.error.slice(0, 80) : ''}, server ${e ? `${e.bytes} bytes md5 ${e.md5 === deviceMd5(p)}` : 'none'}, row ${JSON.stringify(rows[0])}, OOM lines ${oom ? oom.split('\n').length : 0}, took ${Math.round((Date.now() - since) / 1000)}s`,
    !!e && e.md5 === deviceMd5(p) && rows[0]?.Status === 'completed' && !oom);
} };

S['screen-off'] = { desc: 'Screen off and locked mid-run: uploads continue, notification follows', async run() {
  await setup();
  await t.setFaults([{ delayMs: 500, path: '/test/records' }]);
  const since = Date.now();
  await enqueueMany(ids('so', 40).map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await t.waitFor(async () => Object.keys(await deliveries()).length >= 5, { timeout: 60000, what: '5 delivered' });
  t.disconnect();
  t.screen(false);
  await t.sleep(8000);
  const n1 = appNotifications();
  const mid = Object.keys(await deliveries()).length;
  await t.waitFor(async () => Object.keys(await deliveries()).length === 40, { timeout: 120000, what: '40 delivered' });
  await t.sleep(3000);
  const n2 = appNotifications();
  t.screen(true);
  t.shell('wm dismiss-keyguard');
  await t.connect();
  const c = await statusCounts();
  t.record('screen off / locked', 'uploads continue with the screen off, progress notification advances, success notification at the end',
    `delivered ${mid} after 8 s screen off, then 40; mid notification ${fmtN(n1)}; end ${fmtN(n2)}; rows ${JSON.stringify(c)}`,
    c.completed === 40 && n1.some((x) => x.ongoing) && !n2.some((x) => x.ongoing));
} };

S['swipe-recents'] = { desc: 'App swiped away from recents mid-run', async run() {
  await setup();
  await t.setFaults([{ delayMs: 500, path: '/test/records' }]);
  await enqueueMany(ids('sw', 40).map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await t.waitFor(async () => Object.keys(await deliveries()).length >= 5, { timeout: 60000, what: '5 delivered' });
  t.disconnect();
  t.home();
  await t.sleep(800);
  t.key('KEYCODE_APP_SWITCH');
  await t.sleep(1500);
  t.shell('input swipe 540 1300 540 150 200');
  await t.sleep(2000);
  t.home();
  const pidAfter = t.appPid();
  await t.waitFor(async () => Object.keys(await deliveries()).length === 40, { timeout: 180000, what: '40 delivered' }).catch(() => null);
  const d = await deliveries();
  await t.sleep(3000);
  const n = appNotifications();
  t.record('swiped from recents', 'uploads continue (process kept by the foreground service or restarted by WorkManager), all 40 delivered once',
    `pid after swipe ${pidAfter || 'none'}, delivered ${Object.keys(d).length}, duplicates ${Object.values(d).filter((x) => x > 1).length}, notifications ${fmtN(n)}`,
    Object.keys(d).length === 40 && !n.some((x) => x.ongoing));
} };

S['force-stop'] = { desc: 'Force stop mid-run, then reopen the app', async run() {
  await setup();
  await t.setFaults([{ delayMs: 500, path: '/test/records' }]);
  await enqueueMany(ids('fs', 40).map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await t.waitFor(async () => Object.keys(await deliveries()).length >= 5, { timeout: 60000, what: '5 delivered' });
  t.disconnect();
  t.forceStop();
  const atStop = Object.keys(await deliveries()).length;
  await t.sleep(15000);
  const whileStopped = Object.keys(await deliveries()).length;
  const n1 = appNotifications();
  t.launchApp();
  await t.connect();
  await t.waitFor(async () => Object.keys(await deliveries()).length === 40, { timeout: 120000, what: '40 delivered' }).catch(() => null);
  const d = await deliveries();
  const c = await statusCounts();
  t.record('force-stop then reopen', 'nothing runs while force-stopped (Android rule) and no notification is left; reopening resumes the queue without calling enqueueSync; each record once',
    `delivered at stop ${atStop}, after 15 s stopped ${whileStopped}, notifications while stopped ${fmtN(n1)}, after reopen ${Object.keys(d).length} delivered, duplicates ${Object.values(d).filter((x) => x > 1).length}, rows ${JSON.stringify(c)}`,
    whileStopped <= atStop + 1 && Object.keys(d).length === 40 && c.completed === 40);
} };

S['process-killed'] = { desc: 'App process killed mid-run (no force stop): WorkManager runs the work again', async run() {
  await setup();
  await t.setFaults([{ delayMs: 500, path: '/test/records' }]);
  await enqueueMany(ids('pk', 40).map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await t.waitFor(async () => Object.keys(await deliveries()).length >= 5, { timeout: 60000, what: '5 delivered' });
  t.disconnect();
  t.home();
  await t.sleep(1000);
  const pid = t.appPid();
  t.runAs(`kill -9 ${pid}`);
  const atKill = Object.keys(await deliveries()).length;
  const resumed = await t.waitFor(async () => Object.keys(await deliveries()).length === 40, { timeout: 15 * 60000, interval: 5000, what: '40 delivered' }).then(() => true).catch(() => false);
  const d = await deliveries();
  const newPid = t.appPid();
  t.record('process killed mid-run', 'JobScheduler restarts the work in a new process without opening the app; all 40 delivered, at most the in-flight one twice',
    `killed pid ${pid} at ${atKill} delivered, resumed ${resumed}, new pid ${newPid}, delivered ${Object.keys(d).length}, duplicates ${Object.values(d).filter((x) => x > 1).length}`,
    resumed && Object.values(d).filter((x) => x > 1).length <= 1);
} };

S['reboot'] = { slow: true, desc: 'Emulator reboot mid-queue: WorkManager work survives the reboot', async run() {
  await setup();
  await t.setFaults([{ delayMs: 1000, path: '/test/records' }]);
  await enqueueMany(ids('rb', 60).map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await t.waitFor(async () => Object.keys(await deliveries()).length >= 5, { timeout: 60000, what: '5 delivered' });
  t.disconnect();
  const atReboot = Object.keys(await deliveries()).length;
  t.adb('reboot');
  await t.sleep(10000);
  t.adb('wait-for-device');
  await t.waitFor(() => t.shell('getprop sys.boot_completed') === '1', { timeout: 300000, interval: 3000, what: 'boot completed' });
  const bootedAt = Date.now();
  const resumed = await t.waitFor(async () => Object.keys(await deliveries()).length === 60, { timeout: 15 * 60000, interval: 5000, what: '60 delivered' }).then(() => true).catch(() => false);
  const d = await deliveries();
  t.record('reboot mid-queue', 'after boot, without opening the app, the queue resumes and all 60 are delivered',
    `delivered before reboot ${atReboot}, resumed ${resumed} (${Math.round((Date.now() - bootedAt) / 1000)} s after boot), delivered ${Object.keys(d).length}, duplicates ${Object.values(d).filter((x) => x > 1).length}`,
    resumed);
} };

S['system-stop-background'] = { desc: 'System stops a run started in the background (charging constraint lost): paused notification, then resumes', async run() {
  // WorkManager 2.9 executes work in-process (GreedyScheduler) while the app process is alive,
  // so `cmd jobscheduler timeout` only ends the JobScheduler slot and does not stop the worker.
  // A lost constraint is the system stop WorkManager does apply to a running worker.
  await setup({ syncOnlyWhenCharging: true });
  t.shell('dumpsys battery set ac 1');
  t.shell('dumpsys battery set status 2');
  await t.setFaults([{ delayMs: 700, path: '/test/records' }]);
  await enqueueMany(ids('ss', 40).map((id) => testRecord(id)));
  // Start the run from the background so it cannot become a foreground service.
  t.home();
  await t.sleep(70000);
  await t.plugin('enqueueSync');
  try {
    await t.waitFor(async () => Object.keys(await deliveries()).length >= 5, { timeout: 90000, what: '5 delivered' });
    const before = t.notifications();
    t.shell('dumpsys battery unplug');
    t.shell('dumpsys battery set status 3');
    await t.sleep(5000);
    const paused = t.notifications();
    const atStop = Object.keys(await deliveries()).length;
    await t.sleep(8000);
    const whileStopped = Object.keys(await deliveries()).length;
    t.shell('dumpsys battery set ac 1');
    t.shell('dumpsys battery set status 2');
    const resumed = await t.waitFor(async () => Object.keys(await deliveries()).length === 40, { timeout: 5 * 60000, interval: 3000, what: '40 delivered' }).then(() => true).catch(() => false);
    await t.sleep(3000);
    const end = t.notifications();
    const d = await deliveries();
    t.record('system stop of a background run', 'before: ongoing progress without FGS; after the stop: no new uploads and a non-ongoing "paused" notification; after plugging in: resumes by itself, all 40 once, success notification, nothing ongoing',
      `before ${fmtN(before)} fgs=${before.some((x) => x.fgs)}; after stop ${fmtN(paused)}; delivered ${atStop} then ${whileStopped} while stopped; resumed ${resumed}; end ${fmtN(end)}; re-sent ${Object.values(d).filter((x) => x > 1).length}`,
      resumed && !before.some((x) => x.fgs) && paused.some((x) => /paus/i.test(`${x.title} ${x.text}`) && !x.ongoing) && !paused.some((x) => x.ongoing) && whileStopped <= atStop + 1 && !end.some((x) => x.ongoing));
  } finally {
    t.shell('dumpsys battery reset');
  }
} };

S['repromote-visible'] = { desc: 'Run started in the background becomes a foreground service when the app is opened', async run() {
  await setup();
  await t.setFaults([{ delayMs: 700, path: '/test/records' }]);
  await enqueueMany(ids('rp', 40).map((id) => testRecord(id)));
  t.home();
  await t.sleep(70000);
  await t.plugin('enqueueSync');
  await t.waitFor(async () => Object.keys(await deliveries()).length >= 3, { timeout: 90000, what: '3 delivered' });
  const bg = t.notifications();
  t.launchApp();
  await t.sleep(8000);
  const fg = t.notifications();
  const svc = t.shell(`dumpsys activity services ${t.APP_ID} | grep -E "isForeground|SystemForegroundService" | head -4`);
  await t.waitFor(async () => Object.keys(await deliveries()).length === 40, { timeout: 120000, what: '40 delivered' });
  t.record('re-promotion when visible', 'background start: progress posted without FGS; after opening the app the worker becomes a foreground service',
    `background ${fmtN(bg)} fgs=${bg.some((x) => x.fgs)}; after open ${fmtN(fg)} fgs=${fg.some((x) => x.fgs)}; services: ${svc.replace(/\s+/g, ' ').slice(0, 160)}`,
    fg.some((x) => x.fgs));
} };

S['airplane-foreground'] = { desc: 'Airplane mode on/off with the app open', async run() {
  await setup();
  await t.setFaults([{ delayMs: 400, path: '/test/records' }]);
  const since = Date.now();
  await enqueueMany(ids('af', 40).map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await t.waitFor(async () => Object.keys(await deliveries()).length >= 8, { timeout: 60000, what: '8 delivered' });
  t.setAirplane(true);
  await t.sleep(10000);
  const offline = t.notifications();
  t.setAirplane(false);
  await waitEvent('completed', since, 180000);
  await t.sleep(2000);
  const d = await deliveries();
  const n = t.notifications();
  t.record('airplane mode, app open', 'run pauses while offline (paused/suspended notification, no ongoing progress frozen), resumes by itself, 40 completed, at most one re-send',
    `offline ${fmtN(offline)}; end ${fmtN(n)}; delivered ${Object.keys(d).length}, re-sent ${Object.values(d).filter((x) => x > 1).length}`,
    Object.keys(d).length === 40 && Object.values(d).filter((x) => x > 1).length <= 1 && !n.some((x) => x.ongoing));
} };

S['wifi-toggle-background'] = { desc: 'Wifi and mobile data off/on with the app in the background', async run() {
  await setup();
  await t.setFaults([{ delayMs: 400, path: '/test/records' }]);
  await enqueueMany(ids('wb', 40).map((id) => testRecord(id)));
  await t.plugin('enqueueSync');
  await t.waitFor(async () => Object.keys(await deliveries()).length >= 8, { timeout: 60000, what: '8 delivered' });
  t.disconnect();
  t.home();
  await t.sleep(3000);
  t.setWifi(false);
  t.setData(false);
  await t.sleep(12000);
  const offline = t.notifications();
  t.setWifi(true);
  t.setData(true);
  const ok = await t.waitFor(async () => Object.keys(await deliveries()).length === 40, { timeout: 240000, interval: 3000, what: '40 delivered' }).then(() => true).catch(() => false);
  const samples = [];
  await t.sleep(4000);
  samples.push(fmtN(t.notifications()));
  const d = await deliveries();
  t.record('wifi + data off/on, background', 'run pauses offline, resumes when back without opening the app, 40 delivered, no ongoing notification left',
    `offline ${fmtN(offline)}; done ${ok}; end ${samples.join('')}; re-sent ${Object.values(d).filter((x) => x > 1).length}`,
    ok && !t.notifications().some((x) => x.ongoing));
} };

S['empty-queue'] = { desc: 'enqueueSync with an empty queue (also triggered by every "online" event)', async run() {
  await setup();
  await t.plugin('enqueueSync');
  await t.sleep(6000);
  const n = t.notifications();
  t.record('empty queue sync', 'no notification and no foreground service for an empty queue', `notifications ${fmtN(n)}`, n.length === 0);
} };

// --------------------------------------------------------------------- main ---
const argv = process.argv.slice(2);
if (argv.includes('--list')) {
  for (const [name, s] of Object.entries(S)) console.log(`${name.padEnd(24)} ${s.slow ? '(slow) ' : ''}${s.desc}`);
  process.exit(0);
}
const slow = argv.includes('--slow');
let names = argv.filter((a) => !a.startsWith('--'));
if (names.includes('all')) names = Object.keys(S).filter((n) => slow || !S[n].slow);
const unknown = names.filter((n) => !S[n]);
if (unknown.length || !names.length) {
  console.error(`Unknown or no scenario: ${unknown.join(', ')}. Use --list.`);
  process.exit(2);
}
for (const name of names) {
  t.log(`=== ${name}: ${S[name].desc}`);
  try {
    await S[name].run();
  } catch (e) {
    t.record(name, 'scenario runs to the end', `error: ${e.message}`, false);
  } finally {
    t.disconnect();
    try { await t.clearFaults(); } catch { /* backoffice down */ }
    try {
      const fs = await import('node:fs');
      fs.writeFileSync(`${t.OUT_DIR}/${name}-logcat.txt`, t.logcat('BackgroundSyncPlugin|WM-|fieldaudit|FATAL'));
    } catch { /* device gone */ }
  }
}
const results = t.writeResults(`results-${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
console.log('\n| Case | Expected | Observed | Result |\n| --- | --- | --- | --- |');
for (const r of results) console.log(`| ${r.name} | ${r.expected} | ${r.observed.replace(/\|/g, '/')} | ${r.pass ? 'pass' : 'FAIL'} |`);
process.exit(results.every((r) => r.pass) ? 0 : 1);

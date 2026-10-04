// Test cases for the iOS simulator. Each case returns { pass, observed, ... }.
import path from 'node:path';
import fs from 'node:fs';
import crypto from 'node:crypto';
import {
  BASE, DEFAULT_INIT, DEMO_DIR, PHOTOS, app, plugin, tryPlugin, evalApp, http, sleep, waitFor, waitEvent, eventsSince, markEvents,
  fresh, init, serverState, testLog, setFaults, md5Report, queueCounts, summarize, makeFile, memorySampler,
  goHome, foreground, terminate, launch, waitAppReady, appPid, proxy, screenshot, container, waitIdle,
} from './lib.mjs';

const N = PHOTOS.length;
const received = async () => (await serverState()).received.photos;
const dupes = async () => { const s = await serverState(); return s.requests - s.received.photos; };
const startPhotoSync = () => app('startSync');
const waitServer = (n, timeoutMs = 600000) => waitFor(async () => (await received()) >= n, { timeoutMs, what: `${n} photos on the server` });
const completed = (since) => waitEvent('onCompleted', { since, timeoutMs: 900000 });

// Small synthetic upload records against /api/test/upload.
async function enqueueSynthetic(prefix, n, { bytes = 64 * 1024, extra = {} } = {}) {
  const files = [];
  for (let i = 0; i < n; i++) {
    const id = `${prefix}-${i}`;
    const f = makeFile(`${id}.bin`, bytes);
    files.push({ id, ...f });
    await plugin('enqueueRecord', { id, endpoint: 'api/test/upload', payload: { id }, filePath: f.uri, ...extra });
  }
  return files;
}

export const CASES = [
  {
    id: 'full-sync',
    title: 'Full 336-photo foreground sync',
    expected: '336/336 on the server with md5 match, 336 completed rows, 1 onStarted, 336 onProgress, 0 onFailed, 1 onCompleted',
    async run({ log }) {
      await fresh();
      const mem = memorySampler(1000);
      const t0 = Date.now();
      await startPhotoSync();
      const done = await completed();
      const secs = Math.round((Date.now() - t0) / 1000);
      const m = mem.stop();
      const ev = summarize(await eventsSince());
      const md5 = md5Report();
      const q = await queueCounts();
      const d = await dupes();
      const progress = (await eventsSince()).filter((e) => e.name === 'onProgress').map((e) => e.data.completedCount);
      const monotonic = progress.every((v, i) => i === 0 || v === progress[i - 1] + 1);
      log(JSON.stringify({ secs, mem: m, ev, md5, q, d, done: done.data }));
      const pass = md5.match === N && q.completed === N && ev.onStarted === 1 && ev.onProgress === N && !ev.onFailed && ev.onCompleted === 1 && d === 0 && monotonic;
      return { pass, observed: `${md5.match}/${N} md5 match in ${secs} s, rows ${JSON.stringify(q)}, events ${JSON.stringify(ev)}, progress 1..${progress.at(-1)} in order: ${monotonic}, duplicates ${d}, memory ${m.startMB?.toFixed(0)} -> peak ${m.peakMB?.toFixed(0)} MB`, memory: m, events: ev };
    },
  },
  {
    id: 'background',
    title: 'App to background (Home) mid-run and back',
    expected: 'Uploads continue for about 30 s in the background, then stop with nothing lost; back in the foreground the queue resumes on its own, a sync() call at that moment does not start a second concurrent run, and it ends 336/336 with md5 match and no duplicates (at most the one in-flight photo re-sent)',
    async run({ log, outDir }) {
      await fresh();
      await http('POST', '/api/rate?mbps=40');
      await startPhotoSync();
      await waitServer(20);
      goHome();
      const t0 = Date.now();
      const series = [];
      for (const s of [0, 5, 10, 20, 30, 40, 50, 60, 90]) {
        await sleep(Math.max(0, t0 + s * 1000 - Date.now()));
        series.push([s, await received()]);
      }
      log('background series [s, photos]:', JSON.stringify(series));
      const growthAfter40 = series.at(-1)[1] - series.find(([s]) => s === 40)[1];
      const inBackground = series.at(-1)[1] - series[0][1];
      screenshot(path.join(outDir, 'background-home.png'));
      foreground();
      const back = Date.now();
      // An app typically calls sync() again when it comes back (a button, the
      // "online" event): that must not start a second run next to the one
      // that resumes.
      await waitAppReady();
      await plugin('enqueueSync');
      await waitFor(async () => (await received()) > series.at(-1)[1], { timeoutMs: 60000, what: 'uploads to resume after foreground' }).catch(() => null);
      const resumedAfter = (await received()) > series.at(-1)[1] ? Math.round((Date.now() - back) / 1000) : null;
      await http('POST', '/api/rate?mbps=0');
      if (resumedAfter === null) {
        log('queue did not resume on its own; tapping Sync');
        await startPhotoSync();
      }
      await waitServer(N);
      await waitIdle(3000);
      const md5 = md5Report();
      const d = await dupes();
      const ev = summarize(await eventsSince());
      log(JSON.stringify({ md5, d, ev }));
      const pass = inBackground > 0 && growthAfter40 === 0 && resumedAfter !== null && md5.match === N && d <= 1;
      return { pass, observed: `${inBackground} photos sent in the background, ${growthAfter40} after 40 s (series ${JSON.stringify(series)}); ${resumedAfter === null ? 'did NOT resume on its own after foreground' : `resumed ${resumedAfter} s after foreground`}; end ${md5.match}/${N} md5, duplicates ${d}, events ${JSON.stringify(ev)}`, series };
    },
  },
  {
    id: 'terminate',
    title: 'App terminated mid-run and relaunched',
    expected: 'Uploads stop when the process dies; after relaunch the completed rows stay completed, the next sync continues where it stopped, 336/336 md5 match, no loss, at most one duplicate',
    async run({ log }) {
      await fresh();
      await http('POST', '/api/rate?mbps=80');
      await startPhotoSync();
      await waitServer(60);
      terminate();
      const atKill = await received();
      await sleep(5000);
      const afterKill = await received();
      launch();
      await waitAppReady();
      await sleep(2000);
      const q = await queueCounts();
      log('at kill', atKill, 'after 5 s', afterKill, 'rows after relaunch', JSON.stringify(q));
      await http('POST', '/api/rate?mbps=0');
      const resumedOnOwn = await waitFor(async () => (await received()) > afterKill, { timeoutMs: 8000 }).catch(() => false);
      await markEvents();
      await startPhotoSync();
      await waitServer(N);
      await waitIdle(3000);
      const md5 = md5Report();
      const d = await dupes();
      const q2 = await queueCounts();
      const pass = afterKill - atKill <= 1 && (q.completed || 0) >= atKill - 1 && md5.match === N && d <= 1 && q2.completed === N;
      return { pass, observed: `${atKill} on server at kill, ${afterKill} 5 s later; after relaunch rows ${JSON.stringify(q)}; resumed without a sync call: ${!!resumedOnOwn}; after Sync ${md5.match}/${N} md5, duplicates ${d}, rows ${JSON.stringify(q2)}` };
    },
  },
  {
    id: 'network-loss',
    title: 'Network loss (backoffice unreachable) and recovery',
    expected: 'The in-flight upload fails as a connectivity error, the run stops with onFailed, nothing is marked completed that the server did not get; when the server is reachable again the queue resumes on its own (native retry) and ends 336/336 with md5 match',
    async run({ log }) {
      const px = proxy(8799);
      await px.start();
      await fresh({ serverUrl: px.url });
      await http('POST', '/api/rate?mbps=80');
      await startPhotoSync();
      await waitServer(30);
      await px.stop();
      const cut = Date.now();
      const failed = await waitEvent('onFailed', { timeoutMs: 60000 }).catch(() => null);
      const atCut = await received();
      const rows = await queueCounts();
      log('failed event', JSON.stringify(failed && failed.data), 'rows', JSON.stringify(rows));
      await sleep(15000);
      await http('POST', '/api/rate?mbps=0');
      await px.start();
      const back = Date.now();
      const resumed = await waitFor(async () => (await received()) > atCut, { timeoutMs: 120000, what: 'resume after network back' }).catch(() => null);
      const resumedAfter = resumed ? Math.round((Date.now() - back) / 1000) : null;
      if (!resumed) { log('no automatic resume; calling sync'); await plugin('enqueueSync'); }
      await waitServer(N);
      await waitIdle(3000);
      await px.stop();
      await init();
      const md5 = md5Report();
      const d = await dupes();
      const q = await queueCounts();
      const pass = !!failed && /Upload Exception/.test(failed.data.error || '') && (rows.completed || 0) <= atCut && resumedAfter !== null && md5.match === N && d <= 1;
      return { pass, observed: `onFailed ${failed ? Math.round((failed.serverAt - cut) / 1000) + ' s after cut: ' + failed.data.error : 'never'}; rows at cut ${JSON.stringify(rows)} vs ${atCut} on server; ${resumedAfter === null ? 'did NOT resume on its own' : `resumed ${resumedAfter} s after the server came back`}; end ${md5.match}/${N} md5, duplicates ${d}, rows ${JSON.stringify(q)}` };
    },
  },
  {
    id: 'http-errors',
    title: 'Per-item HTTP 500 and 413 do not abort the queue; retry on next sync',
    expected: 'The 5 rejected photos are marked failed with "HTTP 500/413", the other 331 upload in the same run; onCompleted reports 331/336; the next sync retries only the 5 and ends 336/336',
    async run({ log }) {
      await fresh();
      const r500 = PHOTOS.slice(10, 13).map((p) => p.id);
      const r413 = PHOTOS.slice(200, 202).map((p) => p.id);
      await setFaults([{ id: r500, status: 500, times: 3 }, { id: r413, status: 413, times: 2 }]);
      await startPhotoSync();
      const done = await completed();
      const ev = summarize(await eventsSince());
      const queued = await plugin('getQueuedRecords');
      const errs = queued.map((r) => `${r.id}:${r.error.slice(0, 8)}`);
      log('first run', JSON.stringify(done.data), JSON.stringify(ev), errs.join(' '));
      await setFaults([]);
      const mark = await markEvents();
      await plugin('enqueueSync');
      const done2 = await completed(mark);
      const started2 = (await eventsSince(mark)).find((e) => e.name === 'onStarted');
      await waitIdle(2000);
      const md5 = md5Report();
      const pass = done.data.completedCount === N - 5 && ev.onFailed === 5 && queued.length === 5 && queued.every((r) => r.status === 'failed' && /^HTTP (500|413)/.test(r.error)) && started2?.data.totalCount === 5 && md5.match === N;
      return { pass, observed: `run 1: onCompleted ${done.data.completedCount}/${done.data.totalCount}, onFailed x${ev.onFailed}, queued ${errs.join(', ')}; run 2: onStarted total ${started2?.data.totalCount}, onCompleted ${done2.data.completedCount}/${done2.data.totalCount}; end ${md5.match}/${N} md5` };
    },
  },
  {
    id: 'cancel',
    title: 'cancelSync mid-run, then sync again',
    expected: 'onFailed "Synchronization cancelled by user" after the in-flight photo; uploads stop; completed rows stay completed, the rest pending; the next sync finishes 336/336 with no duplicates',
    async run({ log }) {
      await fresh();
      await http('POST', '/api/rate?mbps=80');
      await startPhotoSync();
      await waitServer(25);
      const t = Date.now();
      await plugin('cancelSync');
      const failed = await waitEvent('onFailed', { timeoutMs: 30000 }).catch(() => null);
      const a = await received();
      await sleep(5000);
      const b = await received();
      const q = await queueCounts();
      log('cancel', failed && failed.data, a, b, JSON.stringify(q));
      await http('POST', '/api/rate?mbps=0');
      const mark = await markEvents();
      await plugin('enqueueSync');
      await completed(mark);
      await waitIdle(2000);
      const md5 = md5Report();
      const d = await dupes();
      const pass = failed?.data.error === 'Synchronization cancelled by user' && a === b && (q.completed || 0) === a && md5.match === N && d === 0;
      return { pass, observed: `onFailed after ${failed ? failed.serverAt - t : '-'} ms: "${failed?.data.error}", server ${a} then ${b} 5 s later, rows ${JSON.stringify(q)}; after sync ${md5.match}/${N} md5, duplicates ${d}` };
    },
  },
  {
    id: 'remove-during-run',
    title: 'removeRecords and clearQueue during a run',
    expected: 'Records removed while the run is going are not uploaded; clearQueue mid-run stops further uploads; non-string ids are skipped without a crash',
    async run({ log }) {
      await fresh();
      await http('POST', '/api/rate?mbps=80');
      await startPhotoSync();
      await waitServer(10);
      const removed = PHOTOS.slice(100, 120).map((p) => p.id);
      await plugin('removeRecords', [...removed, null, 42, { a: 1 }]);
      await waitServer(140);
      await sleep(1500);
      const st = await serverState();
      const got = new Set(st.photos.map((p) => p.photoId));
      const leaked = removed.filter((id) => got.has(id));
      // The backoffice counts every POST; a removed record that is still sent
      // (with its payload gone) is rejected with 422 and shows up only here.
      const strayPosts = st.requests - st.received.photos;
      log('removed ids stored:', leaked.length, 'stray POSTs:', strayPosts);
      const before = await received();
      await plugin('clearQueue');
      await sleep(6000);
      const after = await received();
      const rows = await queueCounts();
      await plugin('cancelSync');
      await waitIdle(3000);
      const after2 = await received();
      const alive = !!appPid();
      const pass = leaked.length === 0 && strayPosts === 0 && after - before <= 2 && alive;
      return { pass, observed: `${leaked.length}/20 removed records stored, ${strayPosts} POSTs sent for removed records; clearQueue at ${before} photos, ${after - before} more uploaded in the next 6 s (${after2 - before} in total before the run stopped), rows after clear ${JSON.stringify(rows)}; app alive: ${alive}` };
    },
  },
  {
    id: 'remove-after',
    title: 'removeRecords, removeDownloads, clearQueue after a run, non-string ids',
    expected: 'Completed rows are removed by id; numeric ids work the same as on Android (coerced to text); null and objects are skipped; no crash',
    async run({ log }) {
      await fresh();
      await enqueueSynthetic('ra', 4, { bytes: 1024 });
      await plugin('enqueueRecord', { id: 'ra-num', endpoint: 'api/test/upload', payload: { id: 'ra-num' } });
      const numeric = await tryPlugin('enqueueRecord', { id: 777, endpoint: 'api/test/upload', payload: { id: 777 } });
      log('enqueue numeric id ->', JSON.stringify(numeric));
      if (!appPid()) { launch(); await waitAppReady(); return { pass: false, observed: 'enqueueRecord with a numeric id crashed the app' }; }
      await plugin('enqueueSync');
      await completed();
      const synced = (await plugin('getSyncedRecords')).map((r) => r.id).sort();
      await plugin('removeRecords', ['ra-0', null, 12.5, { x: 1 }, ['ra-1'], 777]);
      const left = (await plugin('getSyncedRecords')).map((r) => r.id).sort();
      await plugin('enqueueDownload', { id: 'rd-1', endpoint: 'api/test/download/json' });
      await plugin('enqueueDownload', { id: '888', endpoint: 'api/test/download/json' });
      await plugin('removeDownloads', [null, 888, 'nope']);
      const dl = (await plugin('getQueuedDownloads')).map((r) => r.id);
      await plugin('clearQueue');
      await plugin('clearDownloadQueue');
      const empty = (await plugin('getSyncedRecords')).length + (await plugin('getQueuedDownloads')).length;
      const alive = !!appPid();
      const pass = alive && numeric.ok && left.join() === 'ra-1,ra-2,ra-3,ra-num' && dl.join() === 'rd-1' && empty === 0;
      return { pass, observed: `numeric enqueue: ${JSON.stringify(numeric.ok ? numeric.value : numeric.error)}; synced ${synced.join(',')}; after removeRecords(['ra-0', null, 12.5, {x}, ['ra-1'], 777]) left ${left.join(',')}; downloads after removeDownloads([null, 888, 'nope']) ${dl.join(',')}; after clear ${empty} rows; alive ${alive}` };
    },
  },
  {
    id: 'bad-input',
    title: 'Non-string and null inputs to enqueue, getCompletedDownloads, headers',
    expected: 'No crash: numeric id/endpoint/strategy are coerced to text, null limit is ignored, numeric/null header values do not crash initialize or the upload',
    async run({ log }) {
      await fresh();
      const results = {};
      const tries = [
        ['enqueueRecord numeric endpoint', 'enqueueRecord', { id: 'bi-1', endpoint: 12, payload: 'x' }],
        ['enqueueRecord numeric strategy', 'enqueueRecord', { id: 'bi-2', endpoint: 'api/test/upload', uploadStrategy: 5 }],
        ['enqueueRecord numeric filePath', 'enqueueRecord', { id: 'bi-3', endpoint: 'api/test/upload', filePath: 99 }],
        ['enqueueDownload numeric id', 'enqueueDownload', { id: 5, endpoint: 'api/test/download/json' }],
        ['getCompletedDownloads null limit', 'getCompletedDownloads', { limit: null, offset: null }],
        ['getCompletedDownloads string limit', 'getCompletedDownloads', { limit: '2', offset: '0' }],
        ['initialize numeric/null headers', 'initialize', { ...DEFAULT_INIT, headers: { 'X-Api-Key': 'demo-device-key', 'X-Num': 5, 'X-Null': null } }],
      ];
      for (const [label, method, arg] of tries) {
        const r = await tryPlugin(method, arg);
        const alive = !!appPid();
        results[label] = alive ? (r.ok ? 'ok' : `error: ${r.error}`) : 'CRASH';
        log(label, '->', results[label]);
        if (!alive) { launch(); await waitAppReady(); await init(); }
      }
      // Upload with the odd headers in place.
      await plugin('clearQueue');
      await plugin('enqueueRecord', { id: 'bi-h', endpoint: 'api/test/upload', payload: { id: 'bi-h' } });
      await markEvents();
      await plugin('enqueueSync');
      const done = await waitEvent('onCompleted', { timeoutMs: 30000 }).catch(() => null);
      const alive = !!appPid();
      results['upload with numeric header'] = alive ? (done ? `ok ${done.data.completedCount}/${done.data.totalCount}` : 'no onCompleted') : 'CRASH';
      if (!alive) { launch(); await waitAppReady(); }
      await init();
      const pass = Object.values(results).every((v) => !/CRASH/.test(v));
      return { pass, observed: Object.entries(results).map(([k, v]) => `${k}: ${v}`).join('; ') };
    },
  },
  {
    id: 'dup-ids',
    title: 'Duplicate record ids',
    expected: 'Enqueuing an id twice keeps one row with the latest payload; re-enqueuing a completed id makes it pending again and it uploads once more',
    async run({ log }) {
      await fresh();
      await plugin('enqueueRecord', { id: 'dup', endpoint: 'api/test/upload', payload: { id: 'dup', v: 1 } });
      await plugin('enqueueRecord', { id: 'dup', endpoint: 'api/test/upload', payload: { id: 'dup', v: 2 } });
      const rows = await plugin('executeRawQuery', "SELECT Id, Payload, Status FROM sync_queue WHERE Id = 'dup'", []);
      await plugin('enqueueSync');
      await completed();
      await plugin('enqueueRecord', { id: 'dup', endpoint: 'api/test/upload', payload: { id: 'dup', v: 3 } });
      const q = await plugin('getQueuedRecords');
      const mark = await markEvents();
      await plugin('enqueueSync');
      await completed(mark);
      const ups = (await testLog()).filter((e) => e.id === 'dup').map((e) => e.payload.v);
      const pass = rows.length === 1 && JSON.parse(rows[0].Payload).v === 2 && q.length === 1 && ups.join() === '2,3';
      return { pass, observed: `rows after two enqueues: ${rows.length} (payload v=${rows[0] && JSON.parse(rows[0].Payload).v}); re-enqueue of completed id -> queued ${JSON.stringify(q)}; server got versions ${ups.join(',')}` };
    },
  },
  {
    id: 'enqueue-during-run',
    title: 'enqueueRecord and enqueueSync during a run',
    expected: 'Records enqueued during a run are uploaded (in the same or an immediate follow-up run), nothing is uploaded twice, and a second enqueueSync does not report a cancellation the user never asked for',
    async run({ log }) {
      await fresh();
      await http('POST', '/api/rate?mbps=80');
      await startPhotoSync();
      await waitServer(15);
      const extra = await enqueueSynthetic('edr', 5, { bytes: 4096 });
      await Promise.all([plugin('enqueueSync'), plugin('enqueueSync'), plugin('enqueueSync')]);
      await http('POST', '/api/rate?mbps=0');
      await waitServer(N, 600000);
      await waitFor(async () => (await testLog()).filter((e) => e.id?.startsWith('edr-')).length >= 5, { timeoutMs: 120000, what: 'extra records' }).catch(() => null);
      await waitIdle(4000);
      const ev = await eventsSince();
      const cancels = ev.filter((e) => e.name === 'onFailed' && /cancelled/.test(e.data.error || '')).length;
      const extraUp = (await testLog()).filter((e) => e.id?.startsWith('edr-'));
      const d = await dupes();
      const md5 = md5Report();
      log(JSON.stringify(summarize(ev)));
      const pass = extraUp.length === 5 && cancels === 0 && d === 0 && md5.match === N;
      return { pass, observed: `extra records uploaded ${extraUp.length}/5, spurious "cancelled by user" onFailed x${cancels}, photo duplicates ${d}, ${md5.match}/${N} md5, events ${JSON.stringify(summarize(ev))}` };
    },
  },
  {
    id: 'auto-delete',
    title: 'autoDeleteCompleted true (uploads and downloads)',
    expected: 'Behaviour documented: completed downloads are deleted when read with getCompletedDownloads (offset ignored); completed uploads: see observed',
    async run({ log }) {
      await fresh({ autoDeleteCompleted: true });
      await enqueueSynthetic('ad', 3, { bytes: 1024 });
      for (let i = 0; i < 5; i++) await plugin('enqueueDownload', { id: `add-${i}`, endpoint: 'api/test/download/json', payload: { id: `add-${i}` } });
      await plugin('enqueueSync');
      await completed();
      const up = await queueCounts();
      const synced = await plugin('getSyncedRecords');
      const p1 = await plugin('getCompletedDownloads', { limit: 2, offset: 0 });
      const p2 = await plugin('getCompletedDownloads', { limit: 2, offset: 2 });
      const p3 = await plugin('getCompletedDownloads', { limit: 2, offset: 4 });
      const left = await queueCounts('download_queue');
      await init();
      const ids = [...p1.records, ...p2.records, ...p3.records].map((r) => r.id);
      log(JSON.stringify({ up, synced, ids, hasMore: [p1.hasMore, p2.hasMore, p3.hasMore], left }));
      const pass = ids.join() === 'add-0,add-1,add-2,add-3,add-4' && p1.hasMore && p2.hasMore && !p3.hasMore && !left.completed;
      return { pass, observed: `uploads: sync_queue after run ${JSON.stringify(up)}, getSyncedRecords ${synced.length} rows (completed upload rows are deleted on success); downloads paged ${ids.join(',')} hasMore ${[p1.hasMore, p2.hasMore, p3.hasMore]}, left ${JSON.stringify(left)}` };
    },
  },
  {
    id: 'downloads',
    title: 'Download queue: REST and BINARY_FILE, failure, pagination, removal',
    expected: 'started_download, progress_download per item, failed_download for the 404, one onCompleted; listeners named as documented (onStarted_download ...) fire; getCompletedDownloads pages with limit/offset; binary files land with the right md5',
    async run({ log }) {
      await fresh();
      for (let i = 0; i < 4; i++) await plugin('enqueueDownload', { id: `dl-${i}`, endpoint: 'api/test/download/json', payload: { id: `dl-${i}` } });
      await plugin('enqueueDownload', { id: 'dl-get', endpoint: 'api/test/download/json?id=dl-get' });
      const binDir = path.join(container(), 'Documents', 'downloads');
      await plugin('enqueueDownload', { id: 'dl-bin', endpoint: `${BASE}/api/test/download/file/a.bin?bytes=3000000`, filePath: `file://${binDir}/a.bin`, downloadStrategy: 'BINARY_FILE' });
      await plugin('enqueueDownload', { id: 'dl-bad', endpoint: 'api/test/download/json', payload: { id: 'dl-bad' } });
      await setFaults([{ id: 'dl:dl-bad', status: 404 }]);
      // Register listeners with the documented names on top of the app's.
      await evalApp(`
        window.__docNames = [];
        const own = plugin.listeners || {};
        const names = ['onStarted_download','onProgress_download','onFailed_download','onStartedDownload','onProgressDownload','onFailedDownload'];
        const l = { ...own };
        for (const n of names) { const o = own[n]; l[n] = (d) => { window.__docNames.push(n); if (o) o(d); }; }
        plugin.registerListeners(l);
        return true;`);
      await markEvents();
      await plugin('enqueueSync');
      const done = await completed();
      const ev = await eventsSince();
      const fired = await evalApp('return window.__docNames;');
      const queued = await plugin('getQueuedDownloads');
      const all = await plugin('getCompletedDownloads');
      const pages = [];
      for (let off = 0; off < 10; off += 2) { const p = await plugin('getCompletedDownloads', { limit: 2, offset: off }); pages.push(p.records.map((r) => r.id).join('+') + (p.hasMore ? '>' : '')); if (!p.hasMore) break; }
      const binLog = (await testLog()).find((e) => e.id === 'a.bin');
      const binOk = fs.existsSync(path.join(binDir, 'a.bin')) && crypto.createHash('md5').update(fs.readFileSync(path.join(binDir, 'a.bin'))).digest('hex') === binLog?.md5;
      const sample = all.records.find((r) => r.id === 'dl-1');
      await setFaults([]);
      const counts = summarize(ev);
      const order = ev.map((e) => e.name.replace('on', '')).filter((n, i, a) => n !== a[i - 1]).join(' > ');
      log(JSON.stringify({ counts, order, fired: [...new Set(fired)], queued, pages, binOk, sample }));
      const docNamesFire = fired.includes('onStarted_download') && fired.includes('onProgress_download') && fired.includes('onFailed_download');
      const pass = done.data.totalCount === 7 && done.data.completedCount === 6 && queued.length === 1 && /^HTTP 404/.test(queued[0].error) && all.records.length === 6 && binOk && docNamesFire && /"echo":\{"id":"dl-1"\}/.test(sample?.responseData || '');
      return { pass, observed: `onCompleted ${done.data.completedCount}/${done.data.totalCount}; event order ${order}; documented listener names fired: ${docNamesFire} (${[...new Set(fired)].join(',')}); queued ${queued.map((q) => `${q.id}:${q.error.slice(0, 8)}`)}; pages ${pages.join(' | ')}; binary md5 ok ${binOk}; responseData echo ok ${/"echo":\{"id":"dl-1"\}/.test(sample?.responseData || '')}` };
    },
  },
  {
    id: 'presigned',
    title: 'PRESIGNED_URL uploads',
    expected: 'Handshake POST, then a streamed PUT of the file with the returned headers and a guessed Content-Type; md5 matches; a 500 on one handshake fails that record only',
    async run({ log }) {
      await fresh();
      const files = [];
      for (const [id, size, ext] of [['ps-1', 5e6, 'jpg'], ['ps-2', 1e6, 'pdf'], ['ps-3', 2e6, 'bin']]) {
        const f = makeFile(`${id}.${ext}`, size);
        files.push({ id, ...f });
        await plugin('enqueueRecord', { id, endpoint: 'api/test/presign', payload: { id }, filePath: f.uri, uploadStrategy: 'PRESIGNED_URL' });
      }
      await plugin('enqueueRecord', { id: 'ps-missing', endpoint: 'api/test/presign', payload: { id: 'ps-missing' }, filePath: 'file:///nope/missing.jpg', uploadStrategy: 'PRESIGNED_URL' });
      await setFaults([{ id: 'presign:ps-2', status: 500, times: 1 }]);
      await plugin('enqueueSync');
      const done = await completed();
      const logx = await testLog();
      const puts = logx.filter((e) => e.kind === 'put');
      const ok = files.filter((f) => puts.find((p) => p.id === f.id && p.md5 === f.md5));
      const queued = await plugin('getQueuedRecords');
      await setFaults([]);
      log(JSON.stringify({ puts, queued }));
      const ps1 = puts.find((p) => p.id === 'ps-1');
      const pass = done.data.completedCount === 2 && ok.length === 2 && ps1?.contentType === 'image/jpeg' && ps1?.presignedHeader === 'yes' && queued.length === 2;
      return { pass, observed: `onCompleted ${done.data.completedCount}/${done.data.totalCount}; md5 ok for ${ok.map((f) => f.id)}; ps-1 Content-Type ${ps1?.contentType}, custom header ${ps1?.presignedHeader}; failed ${queued.map((q) => `${q.id}: ${q.error.slice(0, 40)}`).join('; ')}` };
    },
  },
  {
    id: 'raw-query',
    title: 'executeRawQuery',
    expected: 'SELECT and PRAGMA return rows; bound args work; writes succeed; invalid SQL and constraint violations return an error',
    async run({ log }) {
      await fresh();
      await plugin('enqueueRecord', { id: 'rq-1', endpoint: 'x', payload: 'p' });
      const r = {};
      r.select = await tryPlugin('executeRawQuery', 'SELECT Id, Status FROM sync_queue WHERE Id = ?', ['rq-1']);
      r.pragma = await tryPlugin('executeRawQuery', 'PRAGMA table_info(sync_queue)', []);
      r.lowerWith = await tryPlugin('executeRawQuery', "  with t as (select 1 as one) select one from t", []);
      r.update = await tryPlugin('executeRawQuery', "UPDATE sync_queue SET Status = 'failed' WHERE Id = ?", ['rq-1']);
      r.after = await tryPlugin('executeRawQuery', 'SELECT Status FROM sync_queue WHERE Id = ?', ['rq-1']);
      r.invalid = await tryPlugin('executeRawQuery', 'SELEC nonsense', []);
      r.constraint = await tryPlugin('executeRawQuery', "INSERT INTO sync_queue (Id, Status) VALUES ('rq-1', 'pending')", []);
      r.numberArg = await tryPlugin('executeRawQuery', 'SELECT ? + 1 AS v', [41]);
      const show = (x) => (x.ok ? JSON.stringify(x.value).slice(0, 60) : `ERROR ${String(x.error).slice(0, 50)}`);
      log(Object.entries(r).map(([k, v]) => `${k}: ${show(v)}`).join('\n    '));
      const pass = r.select.ok && r.select.value[0]?.Status === 'pending' && r.pragma.ok && Array.isArray(r.pragma.value) && r.pragma.value.length === 8 && r.lowerWith.ok && Array.isArray(r.lowerWith.value) && r.update.ok && r.after.value[0]?.Status === 'failed' && !r.invalid.ok && !r.constraint.ok;
      return { pass, observed: Object.entries(r).map(([k, v]) => `${k}: ${show(v)}`).join('; ') };
    },
  },
  {
    id: 'encrypt',
    title: 'encryptDatabase true',
    expected: 'Switching to encryption recreates the database (databaseReset event, documented); the new file is not plain SQLite; records enqueue, upload and survive an app relaunch',
    async run({ log }) {
      await fresh();
      await plugin('enqueueRecord', { id: 'enc-old', endpoint: 'api/test/upload', payload: { id: 'enc-old' } });
      await markEvents();
      await init({ encryptDatabase: true });
      await sleep(1000);
      await plugin('getQueuedRecords');
      const reset = (await eventsSince()).find((e) => e.name === 'onDatabaseReset');
      await enqueueSynthetic('enc', 3, { bytes: 2048 });
      const dbFile = path.join(container(), 'Library/Application Support/bg_sync.db');
      const header = fs.readFileSync(dbFile).subarray(0, 15).toString('latin1');
      // The app initializes the plugin on launch; keep encryption on across the relaunch.
      await evalApp(`localStorage.setItem('fieldbook.initOverrides', JSON.stringify({ encryptDatabase: true, serverUrl: '${BASE}' })); return true;`);
      await sleep(500);
      terminate();
      launch();
      await waitAppReady();
      const q = (await plugin('getQueuedRecords')).map((r) => r.id);
      await markEvents();
      await plugin('enqueueSync');
      const done = await completed();
      const ups = (await testLog()).filter((e) => e.id?.startsWith('enc-')).map((e) => e.id);
      await evalApp("localStorage.removeItem('fieldbook.initOverrides'); return true;");
      await init({ encryptDatabase: false });
      await sleep(1000);
      await plugin('getQueuedRecords');
      const header2 = fs.readFileSync(dbFile).subarray(0, 15).toString('latin1');
      log(JSON.stringify({ reset: reset?.data, header, q, done: done.data, ups, header2 }));
      const pass = !!reset && header !== 'SQLite format 3' && q.join() === 'enc-0,enc-1,enc-2' && done.data.completedCount === 3 && header2 === 'SQLite format 3';
      return { pass, observed: `databaseReset on switch: ${reset ? reset.data.error : 'no event'}; file header encrypted: ${header !== 'SQLite format 3'}; queue after relaunch ${q.join(',')}; uploaded ${ups.join(',')}; switching back to plain: header ${JSON.stringify(header2)}` };
    },
  },
  {
    id: 'large-file',
    title: 'Large files (20 MB and 70 MB) with REST_PAYLOAD',
    expected: 'Both upload with md5 match; memory rise during the upload stays bounded',
    async run({ log }) {
      await fresh();
      const out = [];
      for (const mb of [20, 70]) {
        await plugin('clearQueue');
        const f = makeFile(`big-${mb}.mp4`, mb * 1024 * 1024);
        await plugin('enqueueRecord', { id: `big-${mb}`, endpoint: 'api/test/upload', payload: { id: `big-${mb}` }, filePath: f.uri });
        await sleep(1500);
        const mem = memorySampler(200);
        const mark = await markEvents();
        await plugin('enqueueSync');
        const done = await completed(mark);
        await sleep(1500);
        const m = mem.stop();
        const entry = (await testLog()).find((e) => e.id === `big-${mb}`);
        out.push({ mb, ok: done.data.completedCount === 1 && entry?.file?.md5 === f.md5, rise: m.peakMB - m.startMB, m, contentType: entry?.file?.contentType, slashEscapes: entry?.slashEscapes, bodyMB: entry ? entry.bodyBytes / 1e6 : null });
        log(JSON.stringify(out.at(-1)));
      }
      const pass = out.every((o) => o.ok);
      return { pass, observed: out.map((o) => `${o.mb} MB: md5 ${o.ok ? 'ok' : 'FAIL'}, body ${o.bodyMB?.toFixed(1)} MB, escaped slashes ${o.slashEscapes}, memory ${o.m.startMB?.toFixed(0)} -> peak ${o.m.peakMB?.toFixed(0)} MB (+${o.rise.toFixed(0)})`).join('; '), details: out };
    },
  },
  {
    id: 'inspector-layout',
    title: 'Database Inspector table on a phone-width WKWebView',
    expected: 'Every record is rendered and rows stay short enough to read (under 200 px) at phone width',
    async run({ log }) {
      // Renders the shipped inspector.html inside the app's WKWebView (same engine and width
      // as the native inspector) with a stub bridge fed from the real queue.
      const html = fs.readFileSync(path.join(DEMO_DIR, '..', '..', 'www', 'inspector', 'inspector.html'), 'utf8');
      const code = `
        const rows = await callPlugin('executeRawQuery', ['SELECT * FROM sync_queue ORDER BY Sequence DESC', []]);
        const data = { getSyncQueue: rows, getDownloadQueue: [], getConfig: { serverUrl: 'x', headers: {}, encryptDatabase: false } };
        const f = document.createElement('iframe');
        f.style.cssText = 'position:fixed;left:0;top:0;width:100vw;height:100vh;z-index:99999;border:0';
        document.body.appendChild(f);
        const w = f.contentWindow;
        w.webkit = { messageHandlers: { inspectorBridge: { postMessage: (m) => setTimeout(() => w.__inspectorResolve(m.callId, JSON.stringify(data[m.action] ?? { success: true })), 10) } } };
        f.contentDocument.open(); f.contentDocument.write(${JSON.stringify(html)}); f.contentDocument.close();
        await new Promise((r) => setTimeout(r, 1500));
        const trs = [...f.contentDocument.querySelectorAll('#syncContent tbody tr')];
        const heights = trs.map((t) => t.getBoundingClientRect().height);
        const width = w.innerWidth;
        f.remove();
        return { queued: rows.length, rendered: trs.length, maxRowPx: Math.round(Math.max(0, ...heights)), width };`;
      const r = await evalApp(code, 60000);
      log(JSON.stringify(r));
      const pass = r.queued > 0 && r.rendered === r.queued && r.maxRowPx < 200;
      return { pass, observed: `${r.rendered}/${r.queued} rows rendered at ${r.width} px wide, tallest row ${r.maxRowPx} px` };
    },
  },
];

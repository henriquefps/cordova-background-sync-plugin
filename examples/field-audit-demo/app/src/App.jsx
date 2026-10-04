import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Capacitor } from '@capacitor/core';
import { App as CapApp } from '@capacitor/app';
import {
  ChevronLeft, ChevronRight, Search, MapPin, CalendarDays, Camera, CloudUpload, Check,
  CheckCircle2, WifiOff, CircleAlert, TriangleAlert, OctagonAlert, Eye, Lock, HardDrive,
  ClipboardCheck, ListChecks, Images, CircleDot, RotateCw, User, ArrowUpRight,
} from 'lucide-react';
import data from './data/audit.json';
import * as sync from './sync.js';

const IOS = Capacitor.getPlatform() === 'ios';
// Platform wording: Android runs the queue in WorkManager, iOS in a
// background task that ends about 30 s after the app leaves the screen.
const TEXT = IOS
  ? {
      trigger: 'Sync handed to the native iOS sync task',
      waiting: 'Interrupted. The queue resumes on its own',
      hint: 'You can leave the app. iOS keeps sending for about 30 s, then the queue resumes when you come back.',
    }
  : {
      trigger: 'Sync handed to Android WorkManager',
      waiting: 'Interrupted. Android will retry on its own',
      hint: 'You can lock the phone or leave the app. Android keeps sending.',
    };

const AUDITS = data.audits;
const MAIN = AUDITS[0];
const ALL_PHOTOS = MAIN.areas.flatMap((a) => a.findings.flatMap((f) => f.photos.map((p) => ({ ...p, findingId: f.id, areaId: a.id }))));
const PHOTO_BY_ID = Object.fromEntries(ALL_PHOTOS.map((p) => [p.id, p]));
const FINDING_BY_ID = Object.fromEntries(MAIN.areas.flatMap((a) => a.findings.map((f) => [f.id, { ...f, area: a }])));

const SEVERITY = {
  critical: { label: 'Critical', Icon: OctagonAlert },
  major: { label: 'Major', Icon: TriangleAlert },
  minor: { label: 'Minor', Icon: CircleAlert },
  observation: { label: 'Observation', Icon: Eye },
};

const mb = (bytes, digits = 1) => (bytes / 1e6).toFixed(digits);
const fmtDate = (iso, opts = { day: 'numeric', month: 'short', year: 'numeric' }) =>
  new Date(iso.length === 10 ? iso + 'T12:00:00' : iso).toLocaleDateString('en-GB', opts);
const fmtTime = (t) => new Date(t).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', second: '2-digit' });

function loadLog() {
  try { return JSON.parse(localStorage.getItem('sync-log') || '[]'); } catch { return []; }
}
function saveLog(log) {
  try { localStorage.setItem('sync-log', JSON.stringify(log.slice(0, 60))); } catch { /* storage unavailable */ }
}

// ---------------------------------------------------------------------------
// Sync engine state: listener events + queue queries, nothing simulated.
// ---------------------------------------------------------------------------
function useSyncEngine() {
  const [ready, setReady] = useState(false);
  const [native, setNative] = useState(false);
  const [base, setBase] = useState('');
  const [queued, setQueued] = useState([]);
  const [synced, setSynced] = useState([]);
  const [phase, setPhase] = useState('idle'); // idle | preparing | running | waiting | done
  const [run, setRun] = useState(null); // { completed, total, percentage }
  const [prep, setPrep] = useState(null); // { done, total }
  const [online, setOnline] = useState(navigator.onLine);
  const [log, setLog] = useState(loadLog);
  const refreshing = useRef(false);
  const pendingRefresh = useRef(false);

  const addLog = useCallback((kind, text) => {
    setLog((l) => {
      const next = [{ t: Date.now(), kind, text }, ...l].slice(0, 60);
      saveLog(next);
      return next;
    });
  }, []);

  const refresh = useCallback(async () => {
    if (!sync.isNative()) return;
    if (refreshing.current) { pendingRefresh.current = true; return; }
    refreshing.current = true;
    try {
      const [q, s] = await Promise.all([sync.getQueued(), sync.getSynced()]);
      setQueued(q);
      setSynced(s);
    } catch (e) {
      console.warn('queue query failed', e);
    } finally {
      refreshing.current = false;
      if (pendingRefresh.current) { pendingRefresh.current = false; setTimeout(refresh, 300); }
    }
  }, []);

  useEffect(() => {
    let alive = true;
    (async () => {
      const ok = await sync.whenDeviceReady();
      if (!alive) return;
      setNative(ok);
      if (ok) {
        await sync.initialize();
        sync.requestNotifications();
        setBase(await sync.photoBase());
        sync.registerListeners({
          onStarted: (e) => {
            setPhase('running');
            setRun({ completed: 0, total: e.totalCount, percentage: 0 });
            addLog('start', `Native worker started with ${e.totalCount} photo${e.totalCount === 1 ? '' : 's'} in the queue`);
            refresh();
          },
          onProgress: (e) => {
            setPhase('running');
            setRun({ completed: e.completedCount, total: e.totalCount, percentage: e.percentage });
            refresh();
          },
          onFailed: (e) => {
            setPhase('waiting');
            const msg = (e.error || '').replace(/^Upload Exception:\s*/, '');
            addLog('fail', `Upload interrupted after ${e.completedCount} of ${e.totalCount}${msg ? `: ${msg}` : ''}`);
            refresh();
          },
          onCompleted: (e) => {
            setPhase('done');
            setRun({ completed: e.completedCount, total: e.totalCount, percentage: 100 });
            addLog('done', `Run finished, ${e.completedCount} photo${e.completedCount === 1 ? '' : 's'} delivered`);
            refresh();
          },
        });
        await refresh();
      }
      setReady(true);
    })();
    const on = () => { setOnline(true); addLog('net', 'Device back online'); };
    const off = () => { setOnline(false); addLog('net', 'Device offline'); };
    window.addEventListener('online', on);
    window.addEventListener('offline', off);
    let sub;
    CapApp.addListener('resume', () => refresh()).then((s) => { sub = s; }).catch(() => {});
    const poll = setInterval(refresh, 2000);
    return () => {
      alive = false;
      window.removeEventListener('online', on);
      window.removeEventListener('offline', off);
      sub?.remove();
      clearInterval(poll);
    };
  }, [addLog, refresh]);

  const syncedIds = useMemo(() => new Set(synced.map((r) => r.id)), [synced]);
  const queuedIds = useMemo(() => new Set(queued.map((r) => r.id)), [queued]);
  const syncedBytes = useMemo(() => synced.reduce((n, r) => n + (PHOTO_BY_ID[r.id]?.bytes || 0), 0), [synced]);

  // When the queue drains completely, the audit is done even if the
  // completed event fired while the WebView was suspended.
  useEffect(() => {
    if (ready && native && synced.length >= ALL_PHOTOS.length && queued.length === 0 && phase !== 'done') setPhase('done');
  }, [ready, native, synced.length, queued.length, phase]);

  // Outbox step: queue every photo that is not in the plugin's queue yet,
  // then hand the queue to the native worker.
  const startSync = useCallback(async () => {
    if (!sync.isNative()) return;
    const [q, s] = await Promise.all([sync.getQueued(), sync.getSynced()]);
    const known = new Set([...q, ...s].map((r) => r.id));
    const todo = ALL_PHOTOS.filter((p) => !known.has(p.id));
    if (todo.length) {
      setPhase('preparing');
      setPrep({ done: 0, total: todo.length });
      for (let i = 0; i < todo.length; i++) {
        const p = todo[i];
        await sync.enqueueRecord({
          id: p.id,
          endpoint: sync.PHOTO_ENDPOINT,
          payload: JSON.stringify({
            auditId: MAIN.id,
            areaId: p.areaId,
            findingId: p.findingId,
            photoId: p.id,
            fileName: p.name,
            bytes: p.bytes,
            takenAt: p.takenAt,
          }),
          filePath: `${base}/audits/${MAIN.id}/photos/${p.file}`,
        });
        if (i % 8 === 7 || i === todo.length - 1) setPrep({ done: i + 1, total: todo.length });
      }
      addLog('queue', `${todo.length} photos added to the plugin queue`);
    }
    await sync.triggerSync();
    addLog('trigger', TEXT.trigger);
    setPhase((p) => (p === 'preparing' || p === 'idle' || p === 'done' ? 'running' : p));
    setPrep(null);
    refresh();
  }, [base, addLog, refresh]);

  return { ready, native, base, queued, synced, syncedIds, queuedIds, syncedBytes, phase, run, prep, online, log, startSync, refresh };
}

// ---------------------------------------------------------------------------
// UI pieces
// ---------------------------------------------------------------------------
function TopBar({ title, sub, onBack, right }) {
  return (
    <header className="topbar">
      {onBack ? (
        <button className="icon-btn" onClick={onBack} aria-label="Back"><ChevronLeft size={22} /></button>
      ) : <span className="topbar-pad" />}
      <div className="topbar-title">
        <div className="t">{title}</div>
        {sub && <div className="s">{sub}</div>}
      </div>
      {right || <span className="topbar-pad" />}
    </header>
  );
}

function SeverityTag({ severity }) {
  const s = SEVERITY[severity];
  return <span className={`sev sev-${severity}`}><s.Icon size={12} strokeWidth={2.4} />{s.label}</span>;
}

function Thumb({ engine, photo, showState = true }) {
  const src = engine.base ? Capacitor.convertFileSrc(`${engine.base}/audits/${MAIN.id}/thumbs/${photo.file}`) : '';
  const done = engine.syncedIds.has(photo.id);
  return (
    <div className={`thumb ${done ? 'is-synced' : ''}`}>
      {src ? <img src={src} alt="" loading="lazy" decoding="async" /> : <div className="thumb-ph"><Camera size={16} /></div>}
      {showState && done && <span className="thumb-badge"><Check size={11} strokeWidth={3} /></span>}
    </div>
  );
}

function StatusPill({ engine, audit }) {
  if (audit.id !== MAIN.id) return <span className="pill pill-ok"><CheckCircle2 size={13} />Synced</span>;
  const total = ALL_PHOTOS.length;
  const n = engine.synced.length;
  if (n >= total) return <span className="pill pill-ok"><CheckCircle2 size={13} />Synced</span>;
  if (engine.phase === 'waiting' || (!engine.online && engine.queued.length)) return <span className="pill pill-warn"><WifiOff size={13} />Waiting for network</span>;
  if (engine.phase === 'running' || engine.phase === 'preparing' || engine.queued.length) return <span className="pill pill-run"><RotateCw size={13} className="spin" />Syncing {Math.round((n / total) * 100)}%</span>;
  return <span className="pill pill-idle"><CloudUpload size={13} />Ready to sync</span>;
}

function AuditList({ engine, open }) {
  const pending = engine.synced.length < ALL_PHOTOS.length;
  return (
    <div className="screen">
      <header className="home-head">
        <div className="home-row">
          <div className="brand"><span className="brand-mark"><ClipboardCheck size={18} /></span>Fieldbook</div>
          <div className="avatar">ML</div>
        </div>
        <h1>Audits</h1>
        <div className="search"><Search size={17} /><span>Search audits, sites or findings</span></div>
        <div className="seg-tabs"><span className="on">Assigned to me</span><span>Team</span><span>Archived</span></div>
      </header>
      <div className="list">
        {pending && (
          <div className="banner">
            <CloudUpload size={18} />
            <div>
              <b>{ALL_PHOTOS.length - engine.synced.length} photos waiting to sync</b>
              <span>{mb(MAIN.totalBytes - engine.syncedBytes)} MB from one audit</span>
            </div>
          </div>
        )}
        <div className="list-label">This month</div>
        {AUDITS.map((a) => (
          <button key={a.id} className="audit-card" onClick={() => open({ name: 'audit', id: a.id })}>
            <div className="audit-card-top">
              <span className="audit-id">{a.id}</span>
              <StatusPill engine={engine} audit={a} />
            </div>
            <div className="audit-title">{a.title}</div>
            <div className="audit-meta"><MapPin size={14} />{a.site}, {a.unit}</div>
            <div className="audit-meta"><CalendarDays size={14} />{fmtDate(a.date)}</div>
            <div className="audit-stats">
              <span><ListChecks size={15} /><b>{a.findingCount}</b> findings</span>
              <span><Images size={15} /><b>{a.photoCount}</b> photos</span>
              <span><HardDrive size={15} /><b>{mb(a.totalBytes)}</b> MB</span>
            </div>
          </button>
        ))}
      </div>
    </div>
  );
}

function SyncButton({ engine, onOpen }) {
  const total = ALL_PHOTOS.length;
  const n = engine.synced.length;
  if (n >= total) {
    return <button className="cta cta-done" onClick={onOpen}><CheckCircle2 size={19} />All {total} photos synced</button>;
  }
  if (engine.phase === 'running' || engine.phase === 'waiting' || engine.phase === 'preparing' || engine.queued.length) {
    return (
      <button className="cta cta-progress" onClick={onOpen}>
        <span className="cta-fill" style={{ width: `${(n / total) * 100}%` }} />
        <span className="cta-label"><RotateCw size={18} className="spin" />View sync, {n} of {total}</span>
      </button>
    );
  }
  return (
    <button className="cta" onClick={async () => { onOpen(); await engine.startSync(); }} disabled={!engine.native}>
      <CloudUpload size={19} />Sync {total} photos, {mb(MAIN.totalBytes)} MB
    </button>
  );
}

function AuditDetail({ engine, id, back, open }) {
  const audit = AUDITS.find((a) => a.id === id);
  const [tab, setTab] = useState('findings');
  if (audit.id !== MAIN.id) {
    return (
      <div className="screen">
        <TopBar title={audit.id} onBack={back} />
        <div className="detail-head">
          <h2>{audit.title}</h2>
          <div className="audit-meta"><MapPin size={14} />{audit.site}, {audit.unit}</div>
          <div className="empty-note"><CheckCircle2 size={20} />This audit and its {audit.photoCount} photos are on the server.</div>
        </div>
      </div>
    );
  }
  const counts = { critical: 0, major: 0, minor: 0, observation: 0 };
  for (const f of Object.values(FINDING_BY_ID)) counts[f.severity]++;
  return (
    <div className="screen with-cta">
      <TopBar title={audit.id} sub="Audit" onBack={back} />
      <div className="detail-head">
        <h2>{audit.title}</h2>
        <div className="audit-meta"><MapPin size={14} />{audit.site}, {audit.unit}</div>
        <div className="audit-meta"><User size={14} />{audit.auditor}<span className="dot-sep" /><CalendarDays size={14} />{fmtDate(audit.date)}</div>
        <div className="tiles">
          <div className="tile"><div className="v">{audit.findingCount}</div><div className="l">Findings</div></div>
          <div className="tile"><div className="v">{audit.photoCount}</div><div className="l">Photos</div></div>
          <div className="tile"><div className="v">{mb(audit.totalBytes)}<small>MB</small></div><div className="l">To upload</div></div>
        </div>
        <div className="sevbar">
          {Object.entries(counts).map(([k, v]) => <span key={k} className={`sevbar-${k}`} style={{ flex: v }} />)}
        </div>
        <div className="sevlegend">
          {Object.entries(counts).map(([k, v]) => <span key={k}><i className={`sw sevbar-${k}`} />{v} {SEVERITY[k].label.toLowerCase()}</span>)}
        </div>
      </div>
      <div className="tabs">
        <button className={tab === 'findings' ? 'on' : ''} onClick={() => setTab('findings')}>Findings</button>
        <button className={tab === 'photos' ? 'on' : ''} onClick={() => setTab('photos')}>Photos <span className="count">{audit.photoCount}</span></button>
      </div>
      {tab === 'findings' ? (
        <div className="areas">
          {audit.areas.map((area) => {
            const photos = area.findings.reduce((n, f) => n + f.photos.length, 0);
            return (
              <section key={area.id} className="area">
                <div className="area-head">
                  <div><div className="area-name">{area.name}</div><div className="area-loc">{area.location}</div></div>
                  <div className="area-count">{area.findings.length} findings, {photos} photos</div>
                </div>
                {area.findings.map((f) => {
                  const done = f.photos.filter((p) => engine.syncedIds.has(p.id)).length;
                  return (
                    <button key={f.id} className="finding" onClick={() => open({ name: 'finding', id: f.id })}>
                      <div className="finding-main">
                        <div className="finding-top"><span className="fid">{f.id}</span><SeverityTag severity={f.severity} /></div>
                        <div className="finding-title">{f.title}</div>
                        <div className="finding-strip">
                          {f.photos.slice(0, 4).map((p) => <Thumb key={p.id} engine={engine} photo={p} showState={false} />)}
                          <span className={`finding-photos ${done === f.photos.length ? 'all' : ''}`}>
                            {done === f.photos.length ? <Check size={13} strokeWidth={3} /> : <Camera size={13} />}
                            {done > 0 && done < f.photos.length ? `${done}/${f.photos.length}` : f.photos.length}
                          </span>
                        </div>
                      </div>
                      <ChevronRight size={18} className="chev" />
                    </button>
                  );
                })}
              </section>
            );
          })}
        </div>
      ) : (
        <div className="photo-tab">
          <div className="photo-summary"><span><b>{engine.synced.length}</b> of {audit.photoCount} on the server</span><span>{mb(engine.syncedBytes)} of {mb(audit.totalBytes)} MB</span></div>
          <div className="grid">
            {ALL_PHOTOS.map((p) => <Thumb key={p.id} engine={engine} photo={p} />)}
          </div>
        </div>
      )}
      <div className="cta-bar"><SyncButton engine={engine} onOpen={() => open({ name: 'sync' })} /></div>
    </div>
  );
}

function FindingDetail({ engine, id, back }) {
  const f = FINDING_BY_ID[id];
  const bytes = f.photos.reduce((n, p) => n + p.bytes, 0);
  return (
    <div className="screen">
      <TopBar title={f.id} sub={f.area.name} onBack={back} />
      <div className="detail-head">
        <SeverityTag severity={f.severity} />
        <h2 className="finding-h">{f.title}</h2>
        <p className="note">{f.note}</p>
        <div className="audit-meta"><MapPin size={14} />{f.area.location}</div>
        <div className="audit-meta"><Camera size={14} />{f.photos.length} photos, {mb(bytes)} MB<span className="dot-sep" />{fmtTime(f.photos[0].takenAt).slice(0, 5)}</div>
      </div>
      <div className="grid grid-2">
        {f.photos.map((p) => <Thumb key={p.id} engine={engine} photo={p} />)}
      </div>
    </div>
  );
}

function Ring({ value }) {
  const r = 86, c = 2 * Math.PI * r;
  return (
    <svg className="ring" viewBox="0 0 200 200">
      <circle cx="100" cy="100" r={r} className="ring-bg" />
      <circle cx="100" cy="100" r={r} className="ring-fg" strokeDasharray={c} strokeDashoffset={c * (1 - value)} />
    </svg>
  );
}

const LOG_ICON = { start: CircleDot, fail: WifiOff, done: CheckCircle2, net: ArrowUpRight, queue: ListChecks, trigger: CloudUpload };

function SyncScreen({ engine, back }) {
  const total = ALL_PHOTOS.length;
  const n = engine.synced.length;
  const pct = Math.floor((n / total) * 100);
  const current = engine.queued[0] && PHOTO_BY_ID[engine.queued[0].id];
  const currentFinding = current && FINDING_BY_ID[current.findingId];
  const done = n >= total;
  let state;
  if (done) state = { cls: 'ok', Icon: CheckCircle2, text: 'All photos are on the server' };
  else if (engine.phase === 'preparing') state = { cls: 'run', Icon: ListChecks, text: `Adding photos to the queue, ${engine.prep?.done || 0} of ${engine.prep?.total || 0}` };
  else if (!engine.online) state = { cls: 'warn', Icon: WifiOff, text: 'Offline. The queue waits for the network' };
  else if (engine.phase === 'waiting') state = { cls: 'warn', Icon: RotateCw, text: TEXT.waiting };
  else if (engine.phase === 'running' || engine.queued.length) state = { cls: 'run', Icon: RotateCw, text: 'Sending in the background' };
  else state = { cls: 'idle', Icon: CloudUpload, text: 'Ready to sync' };

  return (
    <div className="screen sync-screen">
      <TopBar title="Sync" sub={MAIN.id} onBack={back} />
      <div className="sync-hero">
        <div className="ring-wrap">
          <Ring value={n / total} />
          <div className="ring-center">
            <div className="ring-pct">{pct}<small>%</small></div>
            <div className="ring-sub">{n} of {total} photos</div>
          </div>
        </div>
        <div className="sync-mb"><b>{mb(engine.syncedBytes)} MB</b> of {mb(MAIN.totalBytes)} MB on the server</div>
        <div className={`sync-state st-${state.cls}`}><state.Icon size={15} className={state.cls === 'run' ? 'spin' : ''} />{state.text}</div>
      </div>

      <div className="sync-tiles">
        <div className="tile"><div className="v">{engine.queued.length}</div><div className="l">In queue</div></div>
        <div className="tile"><div className="v">{n}</div><div className="l">Synced</div></div>
        <div className="tile"><div className="v">{engine.run ? `${engine.run.completed}/${engine.run.total}` : '0/0'}</div><div className="l">This run</div></div>
      </div>

      {current && !done && (
        <div className="now">
          <Thumb engine={engine} photo={current} showState={false} />
          <div className="now-text">
            <div className="now-label">{engine.online && engine.phase !== 'waiting' ? 'Next in queue' : 'Waiting to send'}</div>
            <div className="now-title">{currentFinding.id} {currentFinding.title}</div>
            <div className="now-sub">{current.name}, {mb(current.bytes, 2)} MB</div>
          </div>
        </div>
      )}

      {!done && (
        <div className="hint"><Lock size={15} />{TEXT.hint}</div>
      )}

      <div className="log">
        <div className="log-head">Activity</div>
        {engine.log.length === 0 && <div className="log-empty">Nothing yet</div>}
        {engine.log.slice(0, 14).map((e, i) => {
          const I = LOG_ICON[e.kind] || CircleDot;
          return (
            <div key={e.t + '-' + i} className={`log-row log-${e.kind}`}>
              <I size={15} />
              <span className="log-text">{e.text}</span>
              <span className="log-time">{fmtTime(e.t)}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

export default function App() {
  const engine = useSyncEngine();
  const [stack, setStack] = useState([{ name: 'audits' }]);
  const route = stack[stack.length - 1];
  const open = useCallback((r) => { setStack((s) => [...s, r]); window.scrollTo(0, 0); }, []);
  const back = useCallback(() => setStack((s) => (s.length > 1 ? s.slice(0, -1) : s)), []);
  const stackRef = useRef(stack);
  stackRef.current = stack;

  useEffect(() => {
    let sub;
    CapApp.addListener('backButton', () => {
      if (stackRef.current.length > 1) back();
      else CapApp.minimizeApp();
    }).then((s) => { sub = s; }).catch(() => {});
    return () => sub?.remove();
  }, [back]);

  // Deep link used by the recording script: fieldbook://open/sync
  useEffect(() => {
    let sub;
    CapApp.addListener('appUrlOpen', ({ url }) => {
      if (url.includes('/sync')) setStack([{ name: 'audits' }, { name: 'audit', id: MAIN.id }, { name: 'sync' }]);
      else if (url.includes('/audit')) setStack([{ name: 'audits' }, { name: 'audit', id: MAIN.id }]);
    }).then((s) => { sub = s; }).catch(() => {});
    return () => sub?.remove();
  }, []);

  return (
    <div className="app">
      {route.name === 'audits' && <AuditList engine={engine} open={open} />}
      {route.name === 'audit' && <AuditDetail engine={engine} id={route.id} back={back} open={open} />}
      {route.name === 'finding' && <FindingDetail engine={engine} id={route.id} back={back} />}
      {route.name === 'sync' && <SyncScreen engine={engine} back={back} />}
    </div>
  );
}

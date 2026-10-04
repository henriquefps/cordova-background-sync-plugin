// Field Audit backoffice: receives the plugin's uploads and shows them live.
//
// Zero dependencies (Node 18+). Implements the REST contract from
// docs/rest-api-signature.md: one POST per record, JSON body
// { payload, file: { filename, contentType, base64Data } }.
//
//   node server.mjs                       listen on :8791
//   PORT=8791 RATE_MBPS=24 node server.mjs  cap ingest at 24 Mbit/s (see README)
//   FAULTS='[{"status":500,"every":7}]' node server.mjs   start with fault rules
//   DATA_DIR=/some/dir node server.mjs    store received files there (default: ./data)
//
// Test support for the Android scripts (../tests, see tests/README.md), always
// on. The iOS suite uses its own layer, test-api.mjs, loaded with TEST_API=1
// and checked first; with it on, its /api/test/log answers instead of this one.
//   POST /api/faults      replace the fault rules (JSON array), DELETE clears them
//   GET  /api/test/log    every request seen per record id (method, status, md5)
//   POST /api/v1/test/records          generic REST_PAYLOAD sink for any payload
//   POST /api/v1/test/presign          presigned URL handshake, then PUT /upload/<key>
//   GET  /api/v1/test/download/<id>    JSON for REST_PAYLOAD downloads
//   GET  /api/v1/test/blob/<id>?bytes=N  deterministic binary for BINARY_FILE downloads
//
// The emulator reaches this server at http://10.0.2.2:8791.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import crypto from 'node:crypto';

// Optional test API (fault injection, remote control of a test build, extra
// endpoints). Loaded only with TEST_API=1; see test-api.mjs.
const testApi = process.env.TEST_API === '1' ? await import('./test-api.mjs') : null;

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8791);
// DATA_DIR keeps two instances (for example the Android and iOS test runs) apart.
const DATA_DIR = process.env.DATA_DIR ? path.resolve(process.env.DATA_DIR) : path.join(HERE, 'data');
const PUBLIC_DIR = path.join(HERE, 'public');
const AUDIT_JSON = path.join(HERE, '..', 'app', 'src', 'data', 'audit.json');
const API_KEY = process.env.API_KEY || 'demo-device-key';
// Ingest bandwidth cap in megabits per second (0 = unlimited). Applied while
// reading each request body, so TCP backpressure slows the phone's upload the
// same way a constrained uplink would.
let rateMbps = Number(process.env.RATE_MBPS || 0);

fs.mkdirSync(DATA_DIR, { recursive: true });

// ------------------------------------------------------------ fault injection ---
// A rule applies to requests whose path contains `path` (default: every API
// request) and whose record id contains `id` (payload.photoId, payload.id, or
// the last path segment). The first matching rule wins. Fields:
//   status      answer with this HTTP status instead of handling the request
//   every       apply only to every Nth matching request (1 = all)
//   times       stop applying after this many hits
//   delayMs     wait before answering (or before the fault)
//   drop        destroy the socket without answering (connection reset)
//   hang        never answer (lets the client time out)
let faults = [];
try { faults = JSON.parse(process.env.FAULTS || '[]'); } catch (e) { console.error('Invalid FAULTS:', e.message); }
const faultState = new Map(); // rule index -> { seen, hits }
function pickFault(pathname, id) {
  for (let i = 0; i < faults.length; i++) {
    const r = faults[i];
    if (r.path && !pathname.includes(r.path)) continue;
    if (!r.path && !pathname.startsWith('/api/v1/') && !pathname.startsWith('/upload/')) continue;
    if (r.id && !(id || '').includes(r.id)) continue;
    const st = faultState.get(i) || { seen: 0, hits: 0 };
    faultState.set(i, st);
    st.seen++;
    if (r.every && st.seen % r.every !== 0) continue;
    if (r.times !== undefined && st.hits >= r.times) continue;
    st.hits++;
    return r;
  }
  return null;
}
// Applies a fault. Returns true when the request was consumed.
async function applyFault(rule, req, res) {
  if (!rule) return false;
  if (rule.delayMs) await new Promise((r) => setTimeout(r, rule.delayMs));
  if (rule.hang) { console.log(`fault: hang ${req.url}`); return true; }
  if (rule.drop) { console.log(`fault: drop ${req.url}`); req.socket.destroy(); return true; }
  if (rule.status) {
    console.log(`fault: HTTP ${rule.status} ${req.url}`);
    send(res, rule.status, { error: `injected fault ${rule.status}` });
    return true;
  }
  return false;
}

// Per record id: every request that reached a handler (for duplicate checks).
const testLog = new Map();
function logTest(id, entry) {
  if (!testLog.has(id)) testLog.set(id, []);
  testLog.get(id).push({ t: Date.now(), ...entry });
}
const md5 = (buf) => crypto.createHash('md5').update(buf).digest('hex');

const audit = JSON.parse(fs.readFileSync(AUDIT_JSON, 'utf8')).audits[0];
const findingIndex = {};
for (const area of audit.areas) {
  for (const f of area.findings) {
    findingIndex[f.id] = { id: f.id, title: f.title, severity: f.severity, area: area.name, expected: f.photos.length };
  }
}

// Received photos, keyed by photoId. Re-sent photos (retries) replace the
// entry instead of being counted twice.
const received = new Map();
const clients = new Set();
let firstAt = null;
let lastAt = null;
let requests = 0;

function loadExisting() {
  const idx = path.join(DATA_DIR, 'received.json');
  if (!fs.existsSync(idx)) return;
  for (const r of JSON.parse(fs.readFileSync(idx, 'utf8'))) received.set(r.photoId, r);
}
function persist() {
  fs.writeFileSync(path.join(DATA_DIR, 'received.json'), JSON.stringify([...received.values()]));
}
loadExisting();

function state() {
  const perFinding = {};
  for (const f of Object.values(findingIndex)) perFinding[f.id] = { ...f, received: 0 };
  let bytes = 0;
  for (const r of received.values()) {
    bytes += r.bytes;
    if (perFinding[r.findingId]) perFinding[r.findingId].received++;
  }
  return {
    audit: { id: audit.id, title: audit.title, site: audit.site, unit: audit.unit, auditor: audit.auditor, date: audit.date },
    expected: { photos: audit.photoCount, bytes: audit.totalBytes },
    received: { photos: received.size, bytes },
    requests,
    rateMbps,
    firstAt,
    lastAt,
    findings: Object.values(perFinding),
    photos: [...received.values()].sort((a, b) => a.receivedAt - b.receivedAt),
  };
}

function broadcast(event, data) {
  const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of clients) res.write(msg);
}

// Read a request body, optionally throttled to rateMbps.
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    const started = Date.now();
    req.on('data', (chunk) => {
      chunks.push(chunk);
      size += chunk.length;
      if (rateMbps > 0) {
        const allowedMs = (size * 8) / (rateMbps * 1e6) * 1000;
        const ahead = allowedMs - (Date.now() - started);
        if (ahead > 5) {
          req.pause();
          setTimeout(() => req.resume(), ahead);
        }
      }
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
    req.on('aborted', () => reject(new Error('client aborted')));
  });
}

function send(res, code, body, type = 'application/json') {
  res.writeHead(code, { 'Content-Type': type, 'Access-Control-Allow-Origin': '*' });
  res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
}

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.jpg': 'image/jpeg', '.woff2': 'font/woff2' };

function serveFile(res, file) {
  fs.readFile(file, (err, buf) => {
    if (err) return send(res, 404, { error: 'not found' });
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
    res.end(buf);
  });
}

async function handleUpload(req, res) {
  if (req.headers['x-api-key'] !== API_KEY) return send(res, 401, { error: 'invalid api key' });
  let body;
  try {
    body = JSON.parse((await readBody(req)).toString('utf8'));
  } catch (e) {
    console.log(`upload aborted or invalid: ${e.message}`);
    if (!res.headersSent && !req.destroyed) send(res, 400, { error: 'invalid body' });
    return;
  }
  requests++;
  const p = body.payload || {};
  if (await applyFault(pickFault(req.url, p.photoId), req, res)) { logTest(p.photoId, { path: req.url, fault: true }); return; }
  if (!p.photoId || !p.findingId || !body.file?.base64Data) return send(res, 422, { error: 'payload.photoId, payload.findingId and file are required' });
  if (!findingIndex[p.findingId]) return send(res, 409, { error: `unknown finding ${p.findingId}` });
  if (testApi?.applyFault(req, res, p.photoId)) return;

  const bin = Buffer.from(body.file.base64Data, 'base64');
  logTest(p.photoId, { path: req.url, status: 200, bytes: bin.length, md5: md5(bin) });
  const dir = path.join(DATA_DIR, p.auditId || 'unknown');
  fs.mkdirSync(dir, { recursive: true });
  const full = path.join(dir, `${p.photoId}.jpg`);
  fs.writeFileSync(full, bin);
  const now = Date.now();
  firstAt ??= now;
  lastAt = now;
  const base = `/files/${encodeURIComponent(p.auditId || 'unknown')}`;
  const record = {
    photoId: p.photoId,
    findingId: p.findingId,
    areaId: p.areaId,
    fileName: body.file.filename,
    originalName: p.fileName,
    bytes: bin.length,
    md5: md5(bin),
    url: `${base}/${encodeURIComponent(p.photoId)}.jpg`,
    thumb: `${base}/${encodeURIComponent(p.photoId)}.jpg`,
    receivedAt: now,
    duplicate: received.has(p.photoId),
  };
  received.set(p.photoId, record);
  persist();
  // Acknowledge first: the device moves on to the next record as soon as the file is stored.
  send(res, 200, { ok: true, photoId: p.photoId });
  const s = state();
  console.log(`${new Date(now).toISOString()} ${String(s.received.photos).padStart(3)}/${audit.photoCount} ${p.photoId} ${(bin.length / 1e6).toFixed(2)} MB${record.duplicate ? ' (re-sent)' : ''}`);

  // Thumbnail of the received file for the live grid (macOS sips; falls back to the full image).
  const thumbDir = path.join(dir, 'thumbs');
  fs.mkdirSync(thumbDir, { recursive: true });
  execFile('sips', ['-Z', '480', full, '--out', path.join(thumbDir, `${p.photoId}.jpg`)], (err) => {
    if (!err) record.thumb = `${base}/thumbs/${encodeURIComponent(p.photoId)}.jpg`;
    broadcast('photo', { photo: record, received: s.received, finding: s.findings.find((f) => f.id === p.findingId), firstAt, lastAt });
  });
}

// ----------------------------------------------------------- test endpoints ---
async function handleTestRecord(req, res) {
  let body;
  try {
    body = JSON.parse((await readBody(req)).toString('utf8'));
  } catch (e) {
    console.log(`test record aborted or invalid: ${e.message}`);
    if (!res.headersSent && !req.destroyed) send(res, 400, { error: 'invalid body' });
    return;
  }
  const p = body.payload && typeof body.payload === 'object' ? body.payload : { raw: body.payload };
  const id = String(p.id ?? 'unknown');
  if (await applyFault(pickFault(req.url, id), req, res)) { logTest(id, { path: req.url, fault: true }); return; }
  const entry = { path: req.url, status: 200, payload: p };
  if (body.file?.base64Data) {
    const bin = Buffer.from(body.file.base64Data, 'base64');
    Object.assign(entry, { bytes: bin.length, md5: md5(bin), filename: body.file.filename, contentType: body.file.contentType });
  }
  logTest(id, entry);
  console.log(`test record ${id}${entry.bytes !== undefined ? ` ${(entry.bytes / 1e6).toFixed(2)} MB` : ''}`);
  send(res, 200, { ok: true, id });
}

const presigned = new Map(); // key -> record id
async function handlePresign(req, res) {
  let body;
  try { body = JSON.parse((await readBody(req)).toString('utf8')); } catch { return send(res, 400, { error: 'invalid body' }); }
  const p = body.payload || {};
  const id = String(p.id ?? 'unknown');
  if (await applyFault(pickFault(req.url, id), req, res)) { logTest(id, { path: req.url, fault: true }); return; }
  const key = crypto.randomBytes(8).toString('hex');
  presigned.set(key, id);
  logTest(id, { path: req.url, status: 200, presignKey: key });
  send(res, 200, {
    uploadUrl: `http://${req.headers.host}/upload/${key}`,
    method: p.method || 'PUT',
    headers: { 'Content-Type': p.contentType || 'application/octet-stream', 'X-Upload-Key': key },
  });
}

async function handlePresignedPut(req, res, key) {
  const id = presigned.get(key);
  if (!id) return send(res, 403, { error: 'unknown or expired upload key' });
  if (await applyFault(pickFault(req.url, id), req, res)) { logTest(id, { path: req.url, fault: true }); return; }
  let bin;
  try { bin = await readBody(req); } catch (e) { console.log(`presigned PUT aborted: ${e.message}`); return; }
  const dir = path.join(DATA_DIR, 'presigned');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `${id}.bin`), bin);
  logTest(id, { path: '/upload', method: req.method, status: 200, bytes: bin.length, md5: md5(bin), contentType: req.headers['content-type'] });
  console.log(`presigned ${req.method} ${id} ${(bin.length / 1e6).toFixed(2)} MB`);
  send(res, 200, { ok: true });
}

// Deterministic bytes for a download id, so the device copy can be checked by md5.
function blobFor(id, bytes) {
  const out = Buffer.alloc(bytes);
  let block = crypto.createHash('sha256').update(id).digest();
  for (let off = 0; off < bytes; off += block.length) {
    block.copy(out, off, 0, Math.min(block.length, bytes - off));
    block = crypto.createHash('sha256').update(block).digest();
  }
  return out;
}

async function handleTestDownload(req, res, url) {
  const parts = url.pathname.split('/');
  const id = decodeURIComponent(parts[parts.length - 1]);
  if (await applyFault(pickFault(url.pathname, id), req, res)) { logTest(id, { path: url.pathname, fault: true }); return; }
  if (url.pathname.includes('/blob/')) {
    const bin = blobFor(id, Number(url.searchParams.get('bytes') || 65536));
    logTest(id, { path: url.pathname, status: 200, bytes: bin.length, md5: md5(bin) });
    return send(res, 200, bin, 'application/octet-stream');
  }
  let payload = null;
  if (req.method === 'POST') {
    try { payload = JSON.parse((await readBody(req)).toString('utf8')).payload; } catch { payload = null; }
  }
  logTest(id, { path: url.pathname, method: req.method, status: 200 });
  send(res, 200, { id, echo: payload, items: [1, 2, 3], at: Date.now() });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  try {
    if (testApi && (await testApi.handleTestApi(req, res, url))) return;
    if (req.method === 'POST' && url.pathname === '/api/v1/audits/photos') return await handleUpload(req, res);
    if (req.method === 'POST' && url.pathname === '/api/v1/test/records') return await handleTestRecord(req, res);
    if (req.method === 'POST' && url.pathname === '/api/v1/test/presign') return await handlePresign(req, res);
    if ((req.method === 'PUT' || req.method === 'POST') && url.pathname.startsWith('/upload/')) return await handlePresignedPut(req, res, url.pathname.slice('/upload/'.length));
    if (url.pathname.startsWith('/api/v1/test/download/') || url.pathname.startsWith('/api/v1/test/blob/')) return await handleTestDownload(req, res, url);
    if (url.pathname === '/api/faults') {
      if (req.method === 'POST') {
        try { faults = JSON.parse((await readBody(req)).toString('utf8') || '[]'); } catch (e) { return send(res, 400, { error: e.message }); }
        faultState.clear();
        console.log(`fault rules: ${JSON.stringify(faults)}`);
      } else if (req.method === 'DELETE') {
        faults = [];
        faultState.clear();
      }
      return send(res, 200, { faults, state: Object.fromEntries(faultState) });
    }
    if (req.method === 'GET' && url.pathname === '/api/test/log') return send(res, 200, Object.fromEntries(testLog));
    if (req.method === 'GET' && url.pathname === '/api/state') return send(res, 200, state());
    // The audit as the device holds it, so the page can lay out one slot per expected photo.
    if (req.method === 'GET' && url.pathname === '/api/audit') return send(res, 200, audit);
    if (req.method === 'GET' && url.pathname === '/api/events') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive', 'Access-Control-Allow-Origin': '*' });
      res.write(`event: state\ndata: ${JSON.stringify(state())}\n\n`);
      clients.add(res);
      const ping = setInterval(() => res.write(': ping\n\n'), 15000);
      req.on('close', () => { clients.delete(res); clearInterval(ping); });
      return;
    }
    if (req.method === 'POST' && url.pathname === '/api/reset') {
      received.clear();
      testLog.clear();
      presigned.clear();
      firstAt = lastAt = null;
      requests = 0;
      fs.rmSync(DATA_DIR, { recursive: true, force: true });
      fs.mkdirSync(DATA_DIR, { recursive: true });
      broadcast('state', state());
      return send(res, 200, { ok: true });
    }
    if (req.method === 'POST' && url.pathname === '/api/rate') {
      rateMbps = Number(url.searchParams.get('mbps') || 0);
      return send(res, 200, { rateMbps });
    }
    if (req.method === 'GET' && url.pathname.startsWith('/files/')) {
      const rel = decodeURIComponent(url.pathname.slice('/files/'.length));
      const file = path.join(DATA_DIR, rel);
      if (!file.startsWith(DATA_DIR)) return send(res, 403, { error: 'forbidden' });
      return serveFile(res, file);
    }
    if (req.method === 'GET') {
      const rel = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
      const file = path.join(PUBLIC_DIR, rel);
      if (!file.startsWith(PUBLIC_DIR)) return send(res, 403, { error: 'forbidden' });
      return serveFile(res, file);
    }
    send(res, 404, { error: 'not found' });
  } catch (e) {
    console.error(e);
    if (!res.headersSent) send(res, 500, { error: e.message });
  }
});

server.requestTimeout = 0;
server.listen(PORT, () => {
  console.log(`Backoffice on http://localhost:${PORT} (emulator: http://10.0.2.2:${PORT}), ingest cap ${rateMbps ? rateMbps + ' Mbit/s' : 'off'}${testApi ? ', test API on' : ''}`);
});

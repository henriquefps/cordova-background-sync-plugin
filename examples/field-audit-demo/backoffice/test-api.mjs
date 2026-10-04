// Test API for the backoffice, enabled with TEST_API=1. Off by default, so the
// demo server behaves exactly as before unless a test run asks for it.
//
// 1. Remote control of a test build of the app (VITE_TEST_CONTROL=1):
//    the app long-polls GET /api/ctl/next for commands, runs them against the
//    plugin, and posts results to /api/ctl/result. Every plugin listener event
//    is forwarded to /api/ctl/event. A test script calls POST /api/ctl/cmd
//    with { kind, method, args } (or { kind: 'eval', code }) and gets the result.
// 2. Fault injection: POST /api/fault with { rules: [...] } makes chosen
//    uploads fail. A rule: { id?: string | string[], status?: number,
//    times?: number, delayMs?: number, mode?: 'status' | 'reset' | 'hang' }.
//    No id matches every record. times defaults to Infinity.
// 3. Generic endpoints for plugin features the photo audit does not use:
//    POST /api/test/upload            any REST_PAYLOAD record, logged with md5
//    POST /api/test/presign           presigned-URL handshake
//    PUT  /api/test/put/:key          presigned-URL target, logged with md5
//    GET|POST /api/test/download/json REST_PAYLOAD download, echoes the payload
//    GET  /api/test/download/file/:name?bytes=N  BINARY_FILE download
//    GET  /api/test/log, POST /api/test/reset
import crypto from 'node:crypto';

const commands = [];
const waiters = []; // pending long-polls from the app
const pending = new Map(); // command id -> resolve
const events = [];
let nextCmd = 1;
let eventSeq = 0;
let lastPollAt = 0;
let rules = [];
const testLog = [];

const md5 = (buf) => crypto.createHash('md5').update(buf).digest('hex');

function json(res, code, body) {
  res.writeHead(code, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
  res.end(JSON.stringify(body));
}

function readAll(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
    req.on('aborted', () => reject(new Error('client aborted')));
  });
}

function dispatch() {
  while (commands.length && waiters.length) {
    const { res, timer } = waiters.shift();
    clearTimeout(timer);
    json(res, 200, commands.shift());
  }
}

// Returns true when a fault rule handled (or dropped) the request.
export function applyFault(req, res, id) {
  const rule = rules.find((r) => r.times > 0 && (r.id == null || [].concat(r.id).includes(id)));
  if (!rule) return false;
  rule.times--;
  rule.hits = (rule.hits || 0) + 1;
  const act = () => {
    if (rule.mode === 'reset') { req.socket.destroy(); return; }
    if (rule.mode === 'hang') return; // never answer; the client times out
    json(res, rule.status || 500, { error: `injected fault ${rule.status || 500}`, id });
  };
  if (rule.delayMs) setTimeout(act, rule.delayMs); else act();
  console.log(`fault: ${rule.mode || 'status'} ${rule.status || ''} for ${id}`);
  return true;
}

export async function handleTestApi(req, res, url) {
  const p = url.pathname;

  // ---- remote control ----
  if (p === '/api/ctl/next' && req.method === 'GET') {
    lastPollAt = Date.now();
    if (commands.length) return json(res, 200, commands.shift()), true;
    const timer = setTimeout(() => {
      const i = waiters.findIndex((w) => w.res === res);
      if (i >= 0) waiters.splice(i, 1);
      json(res, 200, { id: 0 });
    }, 20000);
    waiters.push({ res, timer });
    req.on('close', () => { const i = waiters.findIndex((w) => w.res === res); if (i >= 0) { clearTimeout(waiters[i].timer); waiters.splice(i, 1); } });
    return true;
  }
  if (p === '/api/ctl/result' && req.method === 'POST') {
    const body = JSON.parse((await readAll(req)).toString('utf8'));
    const resolve = pending.get(body.id);
    if (resolve) { pending.delete(body.id); resolve(body); }
    return json(res, 200, { ok: true }), true;
  }
  if (p === '/api/ctl/event' && req.method === 'POST') {
    const body = JSON.parse((await readAll(req)).toString('utf8'));
    for (const e of [].concat(body)) events.push({ ...e, seq: eventSeq++, serverAt: Date.now() });
    return json(res, 200, { ok: true }), true;
  }
  if (p === '/api/ctl/cmd' && req.method === 'POST') {
    const cmd = JSON.parse((await readAll(req)).toString('utf8'));
    const timeoutMs = cmd.timeoutMs || 60000;
    cmd.id = nextCmd++;
    const result = await new Promise((resolve) => {
      pending.set(cmd.id, resolve);
      commands.push(cmd);
      dispatch();
      setTimeout(() => { if (pending.delete(cmd.id)) resolve({ id: cmd.id, ok: false, error: 'timeout: app did not answer' }); }, timeoutMs);
    });
    return json(res, 200, result), true;
  }
  if (p === '/api/ctl/events' && req.method === 'GET') {
    const since = Number(url.searchParams.get('since') || 0);
    return json(res, 200, { events: events.filter((e) => e.seq >= since), next: eventSeq, lastPollAt }), true;
  }
  if (p === '/api/ctl/status' && req.method === 'GET') {
    return json(res, 200, { lastPollAt, polling: waiters.length, queued: commands.length }), true;
  }

  // ---- fault injection ----
  if (p === '/api/fault' && req.method === 'POST') {
    const body = JSON.parse((await readAll(req)).toString('utf8') || '{}');
    rules = (body.rules || []).map((r) => ({ times: Infinity, ...r }));
    return json(res, 200, { rules }), true;
  }
  if (p === '/api/fault' && req.method === 'GET') return json(res, 200, { rules }), true;

  // ---- generic test endpoints ----
  if (p === '/api/test/upload' && req.method === 'POST') {
    const raw = await readAll(req);
    let body;
    try { body = JSON.parse(raw.toString('utf8')); } catch { return json(res, 400, { error: 'invalid json' }), true; }
    const payload = body.payload;
    const id = (payload && typeof payload === 'object' && payload.id) || (body.file && body.file.filename) || null;
    if (applyFault(req, res, id)) return true;
    const file = body.file ? Buffer.from(body.file.base64Data || '', 'base64') : null;
    testLog.push({
      kind: 'upload', id, at: Date.now(), payload, bodyBytes: raw.length,
      headers: { 'x-api-key': req.headers['x-api-key'], 'x-test': req.headers['x-test'], 'content-type': req.headers['content-type'] },
      file: file ? { filename: body.file.filename, contentType: body.file.contentType, bytes: file.length, md5: md5(file) } : null,
      slashEscapes: (raw.toString('latin1').match(/\\\//g) || []).length,
    });
    return json(res, 200, { ok: true, id }), true;
  }
  if (p === '/api/test/presign' && req.method === 'POST') {
    const body = JSON.parse((await readAll(req)).toString('utf8'));
    const id = body.payload && body.payload.id;
    if (applyFault(req, res, `presign:${id}`)) return true;
    const key = encodeURIComponent(id || crypto.randomUUID());
    testLog.push({ kind: 'presign', id, at: Date.now(), payload: body.payload });
    return json(res, 200, { uploadUrl: `http://${req.headers.host}/api/test/put/${key}`, method: 'PUT', headers: { 'x-presigned': 'yes' } }), true;
  }
  if (p.startsWith('/api/test/put/') && req.method === 'PUT') {
    const id = decodeURIComponent(p.slice('/api/test/put/'.length));
    const buf = await readAll(req);
    if (applyFault(req, res, `put:${id}`)) return true;
    testLog.push({ kind: 'put', id, at: Date.now(), bytes: buf.length, md5: md5(buf), contentType: req.headers['content-type'], presignedHeader: req.headers['x-presigned'] });
    res.writeHead(200); res.end();
    return true;
  }
  if (p === '/api/test/download/json') {
    const raw = req.method === 'POST' ? await readAll(req) : Buffer.alloc(0);
    let payload = null;
    try { payload = raw.length ? JSON.parse(raw.toString('utf8')).payload : null; } catch { /* keep null */ }
    const id = (payload && payload.id) || url.searchParams.get('id');
    if (applyFault(req, res, `dl:${id}`)) return true;
    testLog.push({ kind: 'download-json', id, at: Date.now(), method: req.method, payload });
    return json(res, 200, { id, echo: payload, servedAt: Date.now() }), true;
  }
  if (p.startsWith('/api/test/download/file/') && req.method === 'GET') {
    const name = decodeURIComponent(p.slice('/api/test/download/file/'.length));
    if (applyFault(req, res, `file:${name}`)) return true;
    const bytes = Number(url.searchParams.get('bytes') || 1024);
    const buf = crypto.createHash('sha256').update(name).digest();
    const out = Buffer.alloc(bytes);
    for (let i = 0; i < bytes; i++) out[i] = buf[i % buf.length] ^ (i & 0xff);
    testLog.push({ kind: 'download-file', id: name, at: Date.now(), bytes, md5: md5(out) });
    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': bytes });
    res.end(out);
    return true;
  }
  if (p === '/api/test/log' && req.method === 'GET') return json(res, 200, testLog), true;
  if (p === '/api/test/reset' && req.method === 'POST') {
    testLog.length = 0;
    rules = [];
    events.length = 0;
    return json(res, 200, { ok: true }), true;
  }
  return false;
}

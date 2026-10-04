// Remote control for automated tests. Only bundled when the app is built with
// VITE_TEST_CONTROL=1 (see tests/ios/README.md); a normal build never loads it.
//
// The app long-polls the backoffice (TEST_API=1) for commands, runs them
// against the plugin, and posts the results back. Every listener event the
// plugin emits is forwarded too, with the device time, so a test script can
// check the order and counts of onStarted/onProgress/onFailed/onCompleted.
// Requests go through CapacitorHttp (native), so the WebView's origin and
// mixed-content rules do not get in the way.
import { CapacitorHttp } from '@capacitor/core';
import { SERVER_URL } from './sync.js';

const EVENTS = ['onStarted', 'onProgress', 'onFailed', 'onCompleted', 'onStarted_download', 'onProgress_download', 'onFailed_download', 'onStartedDownload', 'onProgressDownload', 'onFailedDownload', 'onDatabaseReset'];
const engine = () => window.cordova?.plugins?.BackgroundSyncPlugin;

let outbox = [];
let flushing = false;
async function flush() {
  if (flushing || !outbox.length) return;
  flushing = true;
  const batch = outbox;
  outbox = [];
  try {
    await CapacitorHttp.post({ url: `${SERVER_URL}/api/ctl/event`, headers: { 'Content-Type': 'application/json' }, data: batch });
  } catch {
    outbox = batch.concat(outbox);
  } finally {
    flushing = false;
    if (outbox.length) setTimeout(flush, batch.length ? 0 : 500);
  }
}

function forward(name, data) {
  outbox.push({ name, t: Date.now(), data });
  flush();
}

// Wrap registerListeners so the app's own listeners keep working and every
// event is also forwarded. The plugin keeps only one listener set.
function patchListeners(e) {
  if (e.__testPatched) return;
  const original = e.registerListeners.bind(e);
  e.registerListeners = (listeners = {}) => {
    if (listeners.__forwarding) return original(listeners);
    const wrapped = { ...listeners, __forwarding: true };
    for (const name of EVENTS) {
      const own = listeners[name];
      wrapped[name] = (data) => { forward(name, data); if (own) own(data); };
    }
    return original(wrapped);
  };
  e.__testPatched = true;
  // The app may have registered before this ran: wrap its listeners now.
  if (e.listeners && Object.keys(e.listeners).length) e.registerListeners(e.listeners);
}

function callPlugin(method, args) {
  return new Promise((resolve, reject) => {
    const e = engine();
    if (!e) return reject(new Error('plugin not available'));
    if (typeof e[method] !== 'function') return reject(new Error(`no method ${method}`));
    e[method](...(args || []), resolve, reject);
  });
}

async function run(cmd, hooks) {
  if (cmd.kind === 'plugin') return callPlugin(cmd.method, cmd.args);
  if (cmd.kind === 'app') return hooks[cmd.method](...(cmd.args || []));
  if (cmd.kind === 'eval') {
    // eslint-disable-next-line no-new-func
    const fn = new Function('plugin', 'hooks', 'callPlugin', `return (async () => { ${cmd.code} })();`);
    return fn(engine(), hooks, callPlugin);
  }
  if (cmd.kind === 'ping') return { platform: window.Capacitor?.getPlatform?.(), at: Date.now() };
  throw new Error(`unknown command kind ${cmd.kind}`);
}

export function startTestControl(hooks) {
  const wait = () => new Promise((r) => {
    if (engine()) return r();
    document.addEventListener('deviceready', r, { once: true });
  });
  wait().then(() => {
    patchListeners(engine());
    forward('testControlReady', { at: Date.now() });
    (async function loop() {
      for (;;) {
        let cmd;
        try {
          const res = await CapacitorHttp.get({ url: `${SERVER_URL}/api/ctl/next`, readTimeout: 30000, connectTimeout: 5000 });
          cmd = res.data;
        } catch {
          await new Promise((r) => setTimeout(r, 1000));
          continue;
        }
        if (!cmd || !cmd.id) continue;
        let result;
        try {
          result = { id: cmd.id, ok: true, value: await run(cmd, hooks) };
        } catch (err) {
          result = { id: cmd.id, ok: false, error: err && err.message ? err.message : err };
        }
        try {
          await CapacitorHttp.post({ url: `${SERVER_URL}/api/ctl/result`, headers: { 'Content-Type': 'application/json' }, data: result });
        } catch { /* the test times out and reports it */ }
      }
    })();
  });
}

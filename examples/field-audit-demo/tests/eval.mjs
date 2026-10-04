// Evaluate one expression in the app's WebView: node eval.mjs "<js>"
// Plugin calls: node eval.mjs "plugin('getQueuedRecords')" (helpers from lib.mjs are in scope).
import * as lib from './lib.mjs';

const expr = process.argv.slice(2).join(' ');
if (!expr) { console.error('usage: node eval.mjs "<expression>"'); process.exit(2); }
await lib.connect();
const fn = new Function(...Object.keys(lib), `return (async () => (${expr}))()`);
try {
  console.log(JSON.stringify(await fn(...Object.values(lib)), null, 2));
} finally {
  lib.disconnect();
}

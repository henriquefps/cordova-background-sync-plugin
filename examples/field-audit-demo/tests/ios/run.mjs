// iOS simulator test runner. Usage:
//   node tests/ios/run.mjs                 run every case
//   node tests/ios/run.mjs full-sync dup   run the named cases
// Needs: the backoffice with TEST_API=1 on BACKOFFICE_PORT, and a test build
// (VITE_TEST_CONTROL=1) installed and seeded on the simulator. See README.md.
import fs from 'node:fs';
import path from 'node:path';
import { CASES } from './cases.mjs';
import { DEMO_DIR } from './lib.mjs';

const wanted = process.argv.slice(2);
const list = wanted.length ? CASES.filter((c) => wanted.includes(c.id)) : CASES;
if (wanted.length && list.length !== wanted.length) {
  console.error(`unknown case; known: ${CASES.map((c) => c.id).join(' ')}`);
  process.exit(2);
}

const outDir = process.env.OUT_DIR || path.join(DEMO_DIR, 'tests/ios/results');
fs.mkdirSync(outDir, { recursive: true });
const results = [];
for (const c of list) {
  const started = Date.now();
  process.stdout.write(`\n=== ${c.id}: ${c.title}\n`);
  let r;
  try {
    r = await c.run({ log: (...a) => console.log('   ', ...a), outDir });
  } catch (e) {
    r = { pass: false, observed: `error: ${e.message}` };
  }
  const row = { id: c.id, title: c.title, expected: c.expected, ...r, seconds: Math.round((Date.now() - started) / 1000) };
  results.push(row);
  console.log(`--- ${row.pass ? 'PASS' : 'FAIL'} ${c.id}: ${row.observed}`);
  fs.writeFileSync(path.join(outDir, `${c.id}.json`), JSON.stringify(row, null, 2));
}

const md = ['| Case | Expected | Observed | Result |', '| --- | --- | --- | --- |']
  .concat(results.map((r) => `| ${r.id}: ${r.title} | ${r.expected} | ${String(r.observed).replace(/\|/g, '/')} | ${r.pass ? 'pass' : 'FAIL'} |`));
fs.writeFileSync(path.join(outDir, 'summary.md'), md.join('\n') + '\n');
console.log('\n' + md.join('\n'));
process.exit(results.every((r) => r.pass) ? 0 : 1);

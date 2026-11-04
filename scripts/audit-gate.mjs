// Fails when pnpm audit reports any high or critical advisory that is not
// explicitly accepted below. Run with: pnpm audit:high
import { execFileSync } from 'node:child_process';

// Accepted until the Next 16 upgrade: next 15 pins postcss 8.4.31, which only
// processes this app's own CSS at build time.
const ACCEPTED = new Set(['GHSA-6g55-p6wh-862q', 'GHSA-r28c-9q8g-f849']);
const BLOCKING = new Set(['high', 'critical']);

let raw;
try {
  raw = execFileSync('pnpm', ['audit', '--json'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
} catch (err) {
  // pnpm audit exits non zero when it finds anything; the JSON is still on stdout.
  raw = err.stdout;
  if (!raw) throw err;
}

const advisories = Object.values(JSON.parse(raw).advisories ?? {});
const blocking = advisories.filter((a) => BLOCKING.has(a.severity) && !ACCEPTED.has(a.github_advisory_id));

for (const a of blocking) {
  console.error(`${a.severity.padEnd(8)} ${a.module_name} ${a.github_advisory_id} ${a.title}`);
}
console.log(`${blocking.length} blocking, ${advisories.length - blocking.length} other or accepted`);
process.exit(blocking.length ? 1 : 0);

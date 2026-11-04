// Fails when pnpm audit reports any high or critical advisory that is not
// explicitly accepted below. Run with: pnpm audit:high
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

// Accepted until the Next 16 upgrade: next 15 pins postcss 8.4.31, which only
// processes this app's own CSS at build time.
const ACCEPTED = new Set(['GHSA-6g55-p6wh-862q', 'GHSA-r28c-9q8g-f849']);
const BLOCKING = new Set(['high', 'critical']);

// Throws unless raw is a real audit report, so a registry or network failure
// can never look like a clean tree.
export function evaluate(raw) {
  const report = JSON.parse(raw);
  const isReport =
    !report.error &&
    report.advisories !== null &&
    typeof report.advisories === 'object' &&
    report.metadata !== null &&
    typeof report.metadata === 'object';
  if (!isReport) {
    throw new Error(`pnpm audit returned no audit report: ${report.error?.message ?? raw.slice(0, 500)}`);
  }

  const advisories = Object.values(report.advisories);
  const blocking = advisories.filter((a) => BLOCKING.has(a.severity) && !ACCEPTED.has(a.github_advisory_id));
  return { blocking, total: advisories.length };
}

function runAudit() {
  try {
    return execFileSync('pnpm', ['audit', '--json'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  } catch (err) {
    // pnpm audit exits non zero when it finds anything; the JSON is still on stdout.
    if (!err.stdout) throw err;
    return err.stdout;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const { blocking, total } = evaluate(runAudit());
  for (const a of blocking) {
    console.error(`${a.severity.padEnd(8)} ${a.module_name} ${a.github_advisory_id} ${a.title}`);
  }
  console.log(`${blocking.length} blocking, ${total - blocking.length} other or accepted`);
  process.exit(blocking.length ? 1 : 0);
}

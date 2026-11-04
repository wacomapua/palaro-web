// Fails when pnpm audit reports any high or critical advisory that is not
// explicitly accepted below. Run with: pnpm audit:high
import { execFileSync } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

// Accepted until the Next 16 upgrade: next 15 pins postcss 8.4.31, which only
// processes this app's own CSS at build time. Each exemption covers that one
// copy only; the same advisory on any other version or path still blocks.
const NEXT_POSTCSS = { version: '8.4.31', path: '.>next>postcss' };
const ACCEPTED = new Map([
  ['GHSA-6g55-p6wh-862q', NEXT_POSTCSS],
  ['GHSA-r28c-9q8g-f849', NEXT_POSTCSS],
]);

function isAccepted(advisory) {
  const scope = ACCEPTED.get(advisory.github_advisory_id);
  const findings = advisory.findings ?? [];
  return (
    Boolean(scope) &&
    findings.length > 0 &&
    findings.every((f) => f.version === scope.version && f.paths?.length > 0 && f.paths.every((p) => p === scope.path))
  );
}
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
  const blocking = advisories.filter((a) => BLOCKING.has(a.severity) && !isAccepted(a));
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

// Resolve symlinks on both sides: import.meta.url is the real path, argv[1] is not.
const isMain = Boolean(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));

if (isMain) {
  const { blocking, total } = evaluate(runAudit());
  for (const a of blocking) {
    console.error(`${a.severity.padEnd(8)} ${a.module_name} ${a.github_advisory_id} ${a.title}`);
  }
  console.log(`${blocking.length} blocking, ${total - blocking.length} other or accepted`);
  process.exit(blocking.length ? 1 : 0);
}

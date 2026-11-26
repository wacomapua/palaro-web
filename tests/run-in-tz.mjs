import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

// TZ is read when a process starts, so behaviour under another process
// timezone is checked in a child node. `body` runs with the module at
// `moduleUrl` bound to `m` and fills `out`, which is returned. The child also
// reports the zone it resolved, so a typo cannot make a test pass vacuously.
export function runInTz(tz, moduleUrl, body) {
  const code = `
    const m = await import(${JSON.stringify(moduleUrl)});
    const out = { resolved: Intl.DateTimeFormat().resolvedOptions().timeZone };
    ${body}
    process.stdout.write(JSON.stringify(out));
  `;
  const r = spawnSync(process.execPath, ['--no-warnings', '--input-type=module', '-e', code], {
    env: { ...process.env, TZ: tz },
    encoding: 'utf8',
  });
  assert.equal(r.status, 0, r.stderr);
  const out = JSON.parse(r.stdout);
  assert.equal(out.resolved, tz, 'child process did not pick up TZ');
  return out;
}

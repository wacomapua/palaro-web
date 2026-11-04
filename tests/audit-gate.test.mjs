import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, chmodSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { evaluate } from '../scripts/audit-gate.mjs';

const report = (advisories) => JSON.stringify({ advisories, metadata: { vulnerabilities: {} } });
const advisory = (id, severity, findings = [{ version: '1.0.0', paths: ['.>pkg'] }]) => ({
  github_advisory_id: id,
  severity,
  module_name: 'pkg',
  title: 't',
  findings,
});
const NEXT_POSTCSS = [{ version: '8.4.31', paths: ['.>next>postcss'] }];

test('fails closed when pnpm returns an error object instead of a report', () => {
  const raw = JSON.stringify({ error: { code: 'ERR_PNPM_AUDIT_BAD_RESPONSE', message: 'registry unreachable' } });
  assert.throws(() => evaluate(raw), /no audit report/);
});

test('fails closed when advisories or metadata are missing', () => {
  assert.throws(() => evaluate(JSON.stringify({ metadata: {} })), /no audit report/);
  assert.throws(() => evaluate(JSON.stringify({ advisories: {} })), /no audit report/);
});

test('blocks unaccepted high and critical advisories only', () => {
  const raw = report({
    1: advisory('GHSA-aaaa-aaaa-aaaa', 'high'),
    2: advisory('GHSA-bbbb-bbbb-bbbb', 'critical'),
    3: advisory('GHSA-cccc-cccc-cccc', 'moderate'),
  });
  assert.deepEqual(evaluate(raw).blocking.map((a) => a.github_advisory_id), ['GHSA-aaaa-aaaa-aaaa', 'GHSA-bbbb-bbbb-bbbb']);
});

test('passes accepted advisories and an empty report', () => {
  assert.equal(evaluate(report({ 1: advisory('GHSA-6g55-p6wh-862q', 'high', NEXT_POSTCSS) })).blocking.length, 0);
  assert.equal(evaluate(report({})).blocking.length, 0);
});

test('an accepted advisory still blocks when it hits another copy or path', () => {
  const otherCopy = [...NEXT_POSTCSS, { version: '8.5.10', paths: ['.>postcss'] }];
  assert.equal(evaluate(report({ 1: advisory('GHSA-6g55-p6wh-862q', 'high', otherCopy) })).blocking.length, 1);
  const otherPath = [{ version: '8.4.31', paths: ['.>next>postcss', '.>autoprefixer>postcss'] }];
  assert.equal(evaluate(report({ 1: advisory('GHSA-r28c-9q8g-f849', 'high', otherPath) })).blocking.length, 1);
  assert.equal(evaluate(report({ 1: advisory('GHSA-r28c-9q8g-f849', 'high', []) })).blocking.length, 1);
});

// CLI layer: run the real script against a fake pnpm on PATH.
const SCRIPT = fileURLToPath(new URL('../scripts/audit-gate.mjs', import.meta.url));

function runGate({ stdout, exitCode, scriptPath = SCRIPT }) {
  const dir = mkdtempSync(join(tmpdir(), 'audit-gate-'));
  try {
    writeFileSync(join(dir, 'out.json'), stdout);
    writeFileSync(join(dir, 'pnpm'), `#!/bin/sh\ncat "${join(dir, 'out.json')}"\nexit ${exitCode}\n`);
    chmodSync(join(dir, 'pnpm'), 0o755);
    let target = scriptPath;
    if (scriptPath === 'symlink') {
      target = join(dir, 'gate-link.mjs');
      symlinkSync(SCRIPT, target);
    }
    return spawnSync(process.execPath, [target], {
      env: { ...process.env, PATH: `${dir}:${process.env.PATH}` },
      encoding: 'utf8',
    }).status;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const blockingReport = report({ 1: advisory('GHSA-aaaa-aaaa-aaaa', 'critical') });

test('cli exits 1 when pnpm prints an error object', () => {
  assert.equal(runGate({ stdout: JSON.stringify({ error: { message: 'offline' } }), exitCode: 1 }), 1);
});

test('cli exits non zero when pnpm fails with empty stdout', () => {
  assert.notEqual(runGate({ stdout: '', exitCode: 1 }), 0);
});

test('cli exits 1 on a blocking report and 0 on a clean one', () => {
  assert.equal(runGate({ stdout: blockingReport, exitCode: 1 }), 1);
  assert.equal(runGate({ stdout: report({}), exitCode: 0 }), 0);
});

test('cli still runs the audit when invoked through a symlink', () => {
  assert.equal(runGate({ stdout: blockingReport, exitCode: 1, scriptPath: 'symlink' }), 1);
});

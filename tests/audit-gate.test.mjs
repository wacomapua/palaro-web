import { test } from 'node:test';
import assert from 'node:assert/strict';
import { evaluate } from '../scripts/audit-gate.mjs';

const report = (advisories) => JSON.stringify({ advisories, metadata: { vulnerabilities: {} } });
const advisory = (id, severity) => ({ github_advisory_id: id, severity, module_name: 'pkg', title: 't' });

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
  assert.equal(evaluate(report({ 1: advisory('GHSA-6g55-p6wh-862q', 'high') })).blocking.length, 0);
  assert.equal(evaluate(report({})).blocking.length, 0);
});

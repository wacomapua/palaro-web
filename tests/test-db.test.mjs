import { test } from 'node:test';
import assert from 'node:assert/strict';
import { evaluateTap, migrationFiles } from '../scripts/test-db.mjs';
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test('passes when every planned test is ok', () => {
  const r = evaluateTap('1..2\nok 1 - a\nok 2 - b\n');
  assert.equal(r.ok, true);
  assert.equal(r.planned, 2);
  assert.equal(r.ran, 2);
  assert.deepEqual(r.failures, []);
});

test('fails on any not ok line and names it', () => {
  const r = evaluateTap('1..2\nok 1 - a\nnot ok 2 - b\n# Failed test 2: "b"\n');
  assert.equal(r.ok, false);
  assert.deepEqual(r.failures, ['not ok 2 - b']);
});

test('fails when the plan is missing', () => {
  const r = evaluateTap('ok 1 - a\n');
  assert.equal(r.ok, false);
  assert.match(r.failures.join('\n'), /no plan/);
});

test('fails when fewer tests ran than were planned', () => {
  const r = evaluateTap('1..3\nok 1 - a\nok 2 - b\n# Looks like you planned 3 tests but ran 2\n');
  assert.equal(r.ok, false);
  assert.match(r.failures.join('\n'), /planned 3 but ran 2/);
});

test('fails when output holds no tests at all', () => {
  assert.equal(evaluateTap('').ok, false);
});

test('ignores indentation psql may add and diagnostics lines', () => {
  const r = evaluateTap(' 1..1\n # note\n ok 1 - a\n');
  assert.equal(r.ok, true);
});

test('migrations are applied in file name order', () => {
  const dir = mkdtempSync(join(tmpdir(), 'mig-'));
  try {
    for (const f of ['20260531000001_b.sql', '0002_a.sql', '0010_c.sql', 'README.md', '20260529000001_x.sql']) {
      writeFileSync(join(dir, f), '');
    }
    mkdirSync(join(dir, 'nested.sql'));
    assert.deepEqual(migrationFiles(dir), [
      '0002_a.sql',
      '0010_c.sql',
      '20260529000001_x.sql',
      '20260531000001_b.sql',
    ]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

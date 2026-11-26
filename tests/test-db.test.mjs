import { test } from 'node:test';
import assert from 'node:assert/strict';
import { evaluateTap, migrationFiles, mustReapply, premigrateSeed, reapplyScript, sessionTestFiles } from '../scripts/test-db.mjs';
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

test('session tests are the node scripts in supabase/tests, in file name order', () => {
  const dir = mkdtempSync(join(tmpdir(), 'tests-'));
  try {
    for (const f of ['b_locks.test.mjs', 'a.test.sql', 'a_locks.test.mjs', 'helper.mjs', 'notes.md']) {
      writeFileSync(join(dir, f), '');
    }
    mkdirSync(join(dir, 'setup'));
    assert.deepEqual(sessionTestFiles(dir), ['a_locks.test.mjs', 'b_locks.test.mjs']);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('finds the premigrate seed named after a migration, if any', () => {
  const dir = mkdtempSync(join(tmpdir(), 'pre-'));
  try {
    writeFileSync(join(dir, '20260531000001_x.sql'), 'select 1;');
    mkdirSync(join(dir, '20260531000002_dir.sql'));
    assert.equal(premigrateSeed(dir, '20260531000001_x.sql'), join(dir, '20260531000001_x.sql'));
    assert.equal(premigrateSeed(dir, '20260531000002_dir.sql'), null, 'a directory is not a seed');
    assert.equal(premigrateSeed(dir, '0001_initial_schema.sql'), null);
    assert.equal(premigrateSeed(join(dir, 'missing'), '20260531000001_x.sql'), null, 'no premigrate directory at all');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// Every timestamped migration must run twice cleanly (a failed or repeated
// `db push` reapplies it). The 000N_ files predate that rule and create types
// and policies without guards.
test('timestamped migrations must reapply cleanly; the early 000N_ files are exempt', () => {
  assert.equal(mustReapply('20260601000001_golf_holes.sql'), true);
  assert.equal(mustReapply('20260529000001_multisport_golf.sql'), true);
  assert.equal(mustReapply('0001_initial_schema.sql'), false);
  assert.equal(mustReapply('0008_venue_marketplace_review_followups.sql'), false);
  // Committed before the rule and cannot be edited; 20260529000003 reconciles it.
  assert.equal(mustReapply('20260529000002_golf_shared_booking_rpcs.sql'), false);
  assert.equal(mustReapply('20260529000003_reconcile_review_followups.sql'), true);
});

test('a reapply runs the migration again inside a transaction that is rolled back', () => {
  const script = reapplyScript('alter table t add column if not exists c int;');
  assert.match(script, /^begin;\n/);
  assert.match(script, /alter table t add column if not exists c int;/);
  assert.match(script, /\nrollback;\n$/);
  // A trailing comment line in the migration cannot swallow the rollback.
  assert.match(reapplyScript('select 1; -- done'), /-- done\n;\nrollback;\n$/);
});

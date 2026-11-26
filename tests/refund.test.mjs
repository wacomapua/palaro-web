import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  DEFAULT_REFUND_POLICY,
  computeRefund,
  formatRefundPolicy,
  normalizeTiers,
  resolveRefundPolicy,
} from '../lib/refund.ts';

const policy = (...tiers) => ({
  tiers: tiers.map(([hours_before, refund_pct]) => ({ hours_before, refund_pct })),
});

// C8 test vectors, shared verbatim with team-manager.
const VECTORS = [
  [
    [[48, 100], [24, 50], [0, 0]],
    ['48h+ before · full refund', '24h+ before · 50% refund', '< 24h · no refund'],
  ],
  [
    [[24, 100], [6, 50], [0, 0]],
    ['24h+ before · full refund', '6h+ before · 50% refund', '< 6h · no refund'],
  ],
  [[[72, 100], [0, 0]], ['72h+ before · full refund', '< 72h · no refund']],
  [[[48, 100], [12, 0]], ['48h+ before · full refund', '< 48h · no refund']],
  [[[0, 100]], ['Any time · full refund']],
  [[[24, 50]], ['24h+ before · 50% refund', '< 24h · no refund']],
  [
    [[0, 0], [48, 100], [24, 50]],
    ['48h+ before · full refund', '24h+ before · 50% refund', '< 24h · no refund'],
  ],
];

for (const [tiers, labels] of VECTORS) {
  test(`C8 labels for ${JSON.stringify(tiers)}`, () => {
    assert.deepEqual(formatRefundPolicy(policy(...tiers)), labels);
  });
}

test('C8: duplicate thresholds keep the first tier after sorting', () => {
  assert.deepEqual(formatRefundPolicy(policy([24, 50], [24, 100], [0, 0])), [
    '24h+ before · 50% refund',
    '< 24h · no refund',
  ]);
});

test('C8: adjacent windows with the same pct merge', () => {
  assert.deepEqual(formatRefundPolicy(policy([48, 100], [24, 100], [0, 0])), [
    '24h+ before · full refund',
    '< 24h · no refund',
  ]);
});

test('C8: no tiers means no refund at any time (as the SQL walk returns 0%)', () => {
  assert.deepEqual(formatRefundPolicy({ tiers: [] }), ['Any time · no refund']);
  assert.deepEqual(formatRefundPolicy(null), ['Any time · no refund']);
});

test('normalizeTiers sorts by hours_before descending', () => {
  assert.deepEqual(normalizeTiers(policy([0, 0], [48, 100], [24, 50]).tiers), policy([48, 100], [24, 50], [0, 0]).tiers);
});

test('normalizeTiers drops duplicate thresholds, keeping the first after a stable sort', () => {
  assert.deepEqual(
    normalizeTiers(policy([0, 0], [24, 50], [48, 100], [24, 100]).tiers),
    policy([48, 100], [24, 50], [0, 0]).tiers,
  );
});

test('normalizeTiers does not mutate its input', () => {
  const input = policy([0, 0], [48, 100]).tiers;
  const copy = structuredClone(input);
  normalizeTiers(input);
  assert.deepEqual(input, copy);
});

test('normalizeTiers keeps an empty list empty', () => {
  assert.deepEqual(normalizeTiers([]), []);
});

test('resolveRefundPolicy: booking snapshot, then slot override, then venue default', () => {
  const snap = policy([0, 100]);
  const slot = policy([72, 100], [0, 0]);
  const venue = policy([48, 100], [24, 50], [0, 0]);
  assert.equal(resolveRefundPolicy(snap, slot, venue), snap);
  assert.equal(resolveRefundPolicy(null, slot, venue), slot);
  assert.equal(resolveRefundPolicy(undefined, null, venue), venue);
  assert.equal(resolveRefundPolicy(null, null, null), DEFAULT_REFUND_POLICY);
});

// computeRefund must agree with the tier walk in cancel_venue_booking. The
// expected refund for every (policy, hours before start) case lives once, in
// supabase/tests/refund_tier_walk.test.sql, which checks the SQL side; this
// test reads the same table and checks the TypeScript side.
function sqlCases() {
  const sql = readFileSync(new URL('../supabase/tests/refund_tier_walk.test.sql', import.meta.url), 'utf8');
  const block = (name) => {
    const m = new RegExp(`-- BEGIN ${name}\\n([\\s\\S]*?)-- END ${name}`).exec(sql);
    assert.ok(m, `missing ${name} block in refund_tier_walk.test.sql`);
    return m[1];
  };
  const policies = new Map();
  for (const m of block('policies').matchAll(/\('([a-z0-9_]+)', '(\{[^']*\})'\)/g)) {
    policies.set(m[1], JSON.parse(m[2]));
  }
  const cases = [...block('cases').matchAll(/\('([a-z0-9_]+)', (-?[\d.]+), (\d+)\)/g)].map((m) => ({
    name: m[1],
    hours: Number(m[2]),
    pct: Number(m[3]),
  }));
  return { policies, cases };
}

test('computeRefund agrees with the SQL tier walk on every shared case', () => {
  const { policies, cases } = sqlCases();
  assert.equal(policies.size, 7, 'all seven C8 policies are in the shared table');
  assert.ok(cases.length >= 40, `expected the full case table, got ${cases.length}`);
  const now = new Date('2026-12-01T00:00:00Z');
  const total = 100000;
  for (const c of cases) {
    const p = policies.get(c.name);
    assert.ok(p, `case refers to unknown policy ${c.name}`);
    const startsAt = new Date(now.getTime() + Math.round(c.hours * 3_600_000));
    const r = computeRefund(total, startsAt, p, now);
    assert.equal(r.refundPct, c.pct, `${c.name} at ${c.hours}h`);
    assert.equal(r.refundCents, Math.round((total * c.pct) / 100), `${c.name} at ${c.hours}h cents`);
  }
});

test('computeRefund with no tiers refunds nothing', () => {
  const now = new Date('2026-12-01T00:00:00Z');
  const r = computeRefund(100000, new Date(now.getTime() + 100 * 3_600_000), { tiers: [] }, now);
  assert.equal(r.refundPct, 0);
  assert.equal(r.refundCents, 0);
});

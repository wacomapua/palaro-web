import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  localInputToUtc,
  closureRequest,
  closureSummary,
  refundWarning,
  affectedBookingLine,
  readClosureResult,
} from '../lib/closures.ts';

const TZ = 'Asia/Manila';
const NOW = new Date('2026-12-01T00:00:00Z');

test('datetime-local input is read as venue wall time', () => {
  assert.equal(localInputToUtc('2026-12-24T18:00', TZ)?.toISOString(), '2026-12-24T10:00:00.000Z');
  assert.equal(localInputToUtc('', TZ), null);
  assert.equal(localInputToUtc('2026-12-24', TZ), null);
});

test('builds create_venue_closure arguments; empty court means the whole venue', () => {
  assert.deepEqual(
    closureRequest({ courtId: '', start: '2026-12-24T18:00', end: '2026-12-25T06:00', reason: '  Christmas  ' }, TZ, NOW),
    {
      ok: true,
      args: {
        _court_id: null,
        _starts_at: '2026-12-24T10:00:00.000Z',
        _ends_at: '2026-12-24T22:00:00.000Z',
        _reason: 'Christmas',
      },
    },
  );
  const r = closureRequest({ courtId: 'c1', start: '2026-12-24T18:00', end: '2026-12-24T19:00', reason: ' ' }, TZ, NOW);
  assert.equal(r.ok && r.args._court_id, 'c1');
  assert.equal(r.ok && r.args._reason, null);
});

test('validates the window before calling the RPC', () => {
  assert.deepEqual(closureRequest({ courtId: '', start: '', end: '2026-12-24T19:00', reason: '' }, TZ, NOW), { ok: false, error: 'Pick a start and end.' });
  assert.deepEqual(closureRequest({ courtId: '', start: '2026-12-24T19:00', end: '2026-12-24T19:00', reason: '' }, TZ, NOW), { ok: false, error: 'End must be after start.' });
  assert.deepEqual(closureRequest({ courtId: '', start: '2026-11-01T08:00', end: '2026-11-30T08:00', reason: '' }, TZ, NOW), { ok: false, error: 'That window has already ended.' });
});

test('reads the RPC row whether supabase-js returns an array or an object', () => {
  const row = { closure_id: 'x', closed_slot_count: 2, refunded_booking_ids: ['b1'] };
  assert.deepEqual(readClosureResult([row]), { closureId: 'x', closedSlots: 2, refundedBookingIds: ['b1'] });
  assert.deepEqual(readClosureResult(row), { closureId: 'x', closedSlots: 2, refundedBookingIds: ['b1'] });
  assert.deepEqual(readClosureResult([{ closure_id: 'y', closed_slot_count: 0, refunded_booking_ids: null }]), { closureId: 'y', closedSlots: 0, refundedBookingIds: [] });
  assert.equal(readClosureResult([]), null);
});

test('summarises what the closure did', () => {
  assert.equal(closureSummary({ closedSlots: 0, refundedBookingIds: [] }), 'Closure added. There were no open slots in that window.');
  assert.equal(closureSummary({ closedSlots: 1, refundedBookingIds: [] }), 'Closure added. Closed 1 slot.');
  assert.equal(closureSummary({ closedSlots: 3, refundedBookingIds: ['a'] }), 'Closure added. Closed 3 slots and cancelled 1 paid booking with a full refund.');
  assert.equal(closureSummary({ closedSlots: 3, refundedBookingIds: ['a', 'b'] }), 'Closure added. Closed 3 slots and cancelled 2 paid bookings with full refunds.');
});

test('a failed refund kick is a warning, not an error', () => {
  assert.equal(refundWarning(null), null);
  assert.equal(
    refundWarning({ message: 'Edge Function returned a non-2xx status code' }),
    'Refunds are queued, but processing did not start (Edge Function returned a non-2xx status code). They will go out the next time refunds are processed.',
  );
  assert.match(refundWarning({}), /^Refunds are queued, but processing did not start\. /);
});

test('describes an affected booking in venue time', () => {
  const line = affectedBookingLine(
    {
      id: 'b1',
      total_cents: 150000,
      party_size: 2,
      captain: { display_name: 'Ana', email: 'ana@x.test' },
      slot: { starts_at: '2026-12-24T10:00:00Z', ends_at: '2026-12-24T11:00:00Z', court: { name: 'Court 1' } },
    },
    TZ,
    'PHP',
  );
  assert.deepEqual(line, { id: 'b1', who: 'Ana (2 players)', when: 'Dec 24, 6:00 PM → Dec 24, 7:00 PM', where: 'Court 1', refund: '₱1,500' });
  const anon = affectedBookingLine({ id: 'b2', total_cents: 0, party_size: 1, captain: null, slot: null }, TZ, 'PHP');
  assert.deepEqual(anon, { id: 'b2', who: 'Player', when: '', where: '', refund: '₱0' });
  assert.equal(affectedBookingLine({ id: 'b3', total_cents: 1, party_size: 1, captain: { display_name: '', email: 'e@x.test' }, slot: null }, TZ, 'PHP').who, 'e@x.test');
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { compareCourtOrder, moveTarget } from '../lib/courts.ts';

const court = (id, sport, sort_order, parent_court_id = null, created_at = '2026-01-01T00:00:00Z') => ({
  id,
  sport,
  sort_order,
  parent_court_id,
  created_at,
});

// The review example: one venue wide sequence across sports.
const venue = [
  court('t1', 'football', 0),
  court('t2', 'football', 1),
  court('t3', 'football', 2),
  court('p1', 'tennis', 3),
  court('p2', 'tennis', 4),
  court('h1', 'football', 5, 't1'),
  court('h2', 'football', 6, 't1'),
];

test('moving P2 up swaps it with P1, not with a football court', () => {
  assert.equal(moveTarget(venue, 'p2', -1), 'p1');
  assert.equal(moveTarget(venue, 'p1', 1), 'p2');
});

test('roots move among roots of their own sport', () => {
  assert.equal(moveTarget(venue, 't2', -1), 't1');
  assert.equal(moveTarget(venue, 't2', 1), 't3');
});

test('the ends of a list have nowhere to go', () => {
  assert.equal(moveTarget(venue, 't1', -1), null);
  assert.equal(moveTarget(venue, 't3', 1), null);
  assert.equal(moveTarget(venue, 'p1', -1), null);
  assert.equal(moveTarget(venue, 'p2', 1), null);
});

test('sub courts move among the children of their parent', () => {
  assert.equal(moveTarget(venue, 'h2', -1), 'h1');
  assert.equal(moveTarget(venue, 'h1', -1), null);
});

test('an unknown court has no target', () => {
  assert.equal(moveTarget(venue, 'nope', 1), null);
});

test('duplicate sort_order values are ordered by created_at, then id (as the RPC renumbers)', () => {
  const dupes = [
    court('b', 'football', 0, null, '2026-01-01T00:00:02Z'),
    court('a', 'football', 0, null, '2026-01-01T00:00:01Z'),
    court('d', 'football', 1, null, '2026-01-01T00:00:03Z'),
    court('c', 'football', 1, null, '2026-01-01T00:00:03Z'),
  ];
  assert.deepEqual([...dupes].sort(compareCourtOrder).map((c) => c.id), ['a', 'b', 'c', 'd']);
  assert.equal(moveTarget(dupes, 'b', -1), 'a');
  assert.equal(moveTarget(dupes, 'c', -1), 'b');
  assert.equal(moveTarget(dupes, 'c', 1), 'd');
});

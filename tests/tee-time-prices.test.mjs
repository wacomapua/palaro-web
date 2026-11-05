import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  MAX_PLAYERS_PER_TEE_TIME,
  centsToPriceText,
  clampPlayersPerTeeTime,
  optionalPriceTextToCents,
  priceTextToCents,
  slotWriteColumns,
  teeSheetRows,
  teeTimePriceColumns,
} from '../lib/tee-sheet.ts';

test('a tee time takes at most 4 players', () => {
  assert.equal(MAX_PLAYERS_PER_TEE_TIME, 4);
  assert.equal(clampPlayersPerTeeTime(4), 4);
  assert.equal(clampPlayersPerTeeTime(6), 4);
  assert.equal(clampPlayersPerTeeTime(0), 1);
  assert.equal(clampPlayersPerTeeTime(Number.NaN), 4, 'an empty field means a foursome');
  assert.equal(clampPlayersPerTeeTime(2.6), 2);
});

test('players per tee time never drops below the golfers already booked', () => {
  assert.equal(clampPlayersPerTeeTime(1, 3), 3);
  // A tee time made before the limit with 5 golfers on it keeps room for them.
  assert.equal(clampPlayersPerTeeTime(6, 5), 5);
});

test('price fields hold whole currency units; blank 9 hole price means not offered', () => {
  assert.equal(priceTextToCents('2500'), 250000);
  assert.equal(priceTextToCents(''), 0);
  assert.equal(optionalPriceTextToCents('1400'), 140000);
  assert.equal(optionalPriceTextToCents(''), null);
  assert.equal(optionalPriceTextToCents('0'), 0, 'free 9 hole rounds are a price, not "not offered"');
  assert.equal(centsToPriceText(140000), '1400');
  assert.equal(centsToPriceText(null), '');
  assert.equal(centsToPriceText(undefined), '');
});

test('a tee time saves the 18 hole price per golfer and the optional 9 hole price', () => {
  assert.deepEqual(teeTimePriceColumns(250000, 140000), {
    price_cents: 250000,
    price_per_player_cents: 250000,
    price_per_player_9_cents: 140000,
  });
  assert.deepEqual(teeTimePriceColumns(250000, null), {
    price_cents: 250000,
    price_per_player_cents: 250000,
    price_per_player_9_cents: null,
  });
});

// What the single slot editor writes (insert or update), review of PR #12
// finding 1: dropping the 9 hole price must fail here.
test('the tee time editor writes the 18 and 9 hole prices and the players per tee time', () => {
  assert.deepEqual(slotWriteColumns({ shared: true, perPlayer: true, priceCents: 250000, price9Cents: 140000, maxPlayers: 4 }), {
    price_cents: 250000,
    price_per_player_cents: 250000,
    price_per_player_9_cents: 140000,
    max_players: 4,
  });
});

test('clearing the 9 hole price writes null, so 9 holes stop being offered', () => {
  assert.deepEqual(slotWriteColumns({ shared: true, perPlayer: true, priceCents: 250000, price9Cents: null, maxPlayers: 3 }), {
    price_cents: 250000,
    price_per_player_cents: 250000,
    price_per_player_9_cents: null,
    max_players: 3,
  });
});

test('court slots write what they always did and never a 9 hole price', () => {
  assert.deepEqual(slotWriteColumns({ shared: false, perPlayer: false, priceCents: 200000, price9Cents: 140000, maxPlayers: 4 }), {
    price_cents: 200000,
    price_per_player_cents: null,
    max_players: null,
  });
});

// What the tee sheet generator inserts.
test('every generated tee time carries both prices, the size and the shared per golfer model', () => {
  const t1 = new Date('2026-11-05T23:00:00.000Z');
  const t2 = new Date('2026-11-05T23:10:00.000Z');
  const rows = teeSheetRows({
    venueId: 'v',
    courtId: 'c',
    currency: 'PHP',
    teeTimes: [t1, t2],
    intervalMinutes: 10,
    priceCents: 250000,
    price9Cents: 140000,
    maxPlayers: 4,
  });
  assert.deepEqual(rows[0], {
    venue_id: 'v',
    court_id: 'c',
    starts_at: '2026-11-05T23:00:00.000Z',
    ends_at: '2026-11-05T23:10:00.000Z',
    price_cents: 250000,
    price_per_player_cents: 250000,
    price_per_player_9_cents: 140000,
    currency: 'PHP',
    status: 'available',
    booking_mode: 'shared',
    pricing_mode: 'per_player',
    max_players: 4,
  });
  assert.equal(rows[1].starts_at, '2026-11-05T23:10:00.000Z');
  assert.equal(rows[1].price_per_player_9_cents, 140000);
  assert.equal(
    teeSheetRows({ venueId: 'v', courtId: 'c', currency: 'PHP', teeTimes: [t1], intervalMinutes: 10, priceCents: 1, price9Cents: null, maxPlayers: 4 })[0]
      .price_per_player_9_cents,
    null,
  );
});

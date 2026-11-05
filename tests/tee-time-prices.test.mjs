import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  MAX_PLAYERS_PER_TEE_TIME,
  centsToPriceText,
  clampPlayersPerTeeTime,
  optionalPriceTextToCents,
  priceTextToCents,
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

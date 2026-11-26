import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as query from '../lib/query.ts';

// What PostgREST returns when a select names a column the database lacks,
// for example venues.timezone before its migration is applied.
const MISSING_COLUMN = {
  data: null,
  error: { message: 'column venues.timezone does not exist', code: '42703' },
};

test('dataOrThrow throws when the query failed instead of reporting no row', () => {
  assert.throws(
    () => query.dataOrThrow(MISSING_COLUMN, 'venue'),
    (err) => {
      assert.ok(err instanceof Error);
      assert.equal(err.message, 'Could not load venue: column venues.timezone does not exist (42703)');
      assert.equal(err.cause, MISSING_COLUMN.error);
      return true;
    },
  );
});

test('dataOrThrow omits the code when PostgREST gives none', () => {
  assert.throws(
    () => query.dataOrThrow({ data: null, error: { message: 'fetch failed' } }, 'booking'),
    { message: 'Could not load booking: fetch failed' },
  );
});

test('dataOrThrow returns null when the row is genuinely missing', () => {
  assert.equal(query.dataOrThrow({ data: null, error: null }, 'venue'), null);
});

test('dataOrThrow returns the row when the query succeeded', () => {
  const venue = { id: 'v1', timezone: 'Asia/Manila' };
  assert.equal(query.dataOrThrow({ data: venue, error: null }, 'venue'), venue);
});

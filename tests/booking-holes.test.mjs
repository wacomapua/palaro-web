import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bookingHolesLabel } from '../lib/tee-sheet.ts';

// Owner booking list and detail: a golf tee time booking (a shared slot)
// shows the round the golfer chose. team-manager decides the same way, by
// booking_mode = 'shared'; exclusive slots store 18 and show nothing.
test('a shared tee time booking shows 9 or 18 holes', () => {
  assert.equal(bookingHolesLabel({ holes: 9, bookingMode: 'shared' }), '9 holes');
  assert.equal(bookingHolesLabel({ holes: 18, bookingMode: 'shared' }), '18 holes');
});

test('a booking made before 9 hole rounds reads as 18 holes', () => {
  assert.equal(bookingHolesLabel({ holes: null, bookingMode: 'shared' }), '18 holes');
  assert.equal(bookingHolesLabel({ holes: undefined, bookingMode: 'shared' }), '18 holes');
});

test('exclusive bookings (courts, range bays) show no holes', () => {
  assert.equal(bookingHolesLabel({ holes: 18, bookingMode: 'exclusive' }), null);
  assert.equal(bookingHolesLabel({ holes: 18, bookingMode: null }), null, 'slot not loaded');
});

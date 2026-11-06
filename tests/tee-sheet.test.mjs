import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildTeeSheets, holesLabel, isTeeSheetCourt, partyLabel, teeTimeLabel } from '../lib/tee-sheet.ts';
import { runInTz } from './run-in-tz.mjs';

const TEE_SHEET_URL = new URL('../lib/tee-sheet.ts', import.meta.url).href;
const MANILA = 'Asia/Manila';

const sharedModel = { slotModel: { bookingMode: 'shared', pricingMode: 'per_player', teeIntervalMinutes: 10, maxPlayers: 4 } };
const exclusiveModel = { slotModel: { bookingMode: 'exclusive', pricingMode: 'per_slot', defaultDurationMinutes: 60 } };
const court = (id, name, sport = 'golf', metadata = sharedModel, kind = 'course') => ({ id, name, sport, kind, metadata });

// 2026-11-06 in Manila (UTC+8): 07:00 local is 23:00 UTC the day before.
const at = (hhmm) => {
  const [h, m] = hhmm.split(':').map(Number);
  return new Date(Date.UTC(2026, 10, 5, 23 + h - 7, m)).toISOString();
};
const slot = (id, courtId, hhmm, extra = {}) => ({
  id,
  court_id: courtId,
  starts_at: at(hhmm),
  ends_at: new Date(new Date(at(hhmm)).getTime() + 10 * 60_000).toISOString(),
  status: 'available',
  booking_mode: 'shared',
  pricing_mode: 'per_player',
  max_players: 4,
  price_cents: 250000,
  price_per_player_cents: 250000,
  price_per_player_9_cents: 140000,
  ...extra,
});
const booking = (id, slotId, party_size, extra = {}) => ({
  id,
  slot_id: slotId,
  status: 'paid',
  party_size,
  holes: 18,
  captain: { display_name: `Captain ${id}` },
  ...extra,
});
const clean = (s) => s.replace(/\s/g, ' ');

test('only golf courses booked as a shared tee sheet get one', () => {
  assert.equal(isTeeSheetCourt(court('c', 'Course')), true);
  assert.equal(isTeeSheetCourt(court('f9', 'Front 9')), true, 'an existing Front 9 course is a tee sheet');
  assert.equal(isTeeSheetCourt(court('b', 'Bay 1', 'golf', exclusiveModel, 'court')), false, 'existing range bays stay on the timeline');
  assert.equal(isTeeSheetCourt(court('t', 'Court 1', 'tennis', null, 'court')), false);
  assert.equal(isTeeSheetCourt(court('legacy', 'Course', 'golf', null, 'course')), true, 'a golf course with no stored model');
});

test('rows are grouped per course, in court order, sorted by tee time', () => {
  const courts = [court('a', 'North Course'), court('bay', 'Bay 1', 'golf', exclusiveModel, 'court'), court('b', 'South Course')];
  const slots = [
    slot('a2', 'a', '07:10'),
    slot('b1', 'b', '07:00'),
    slot('a1', 'a', '07:00'),
    slot('bay1', 'bay', '07:00', { booking_mode: 'exclusive', pricing_mode: 'per_slot', max_players: null }),
  ];
  const sheets = buildTeeSheets({ courts, slots, bookings: [], tz: MANILA });
  assert.deepEqual(
    sheets.map((s) => [s.court.id, s.rows.map((r) => r.slotId)]),
    [
      ['a', ['a1', 'a2']],
      ['b', ['b1']],
    ],
  );
});

test('a course with no tee times that day still gets an empty sheet', () => {
  const sheets = buildTeeSheets({ courts: [court('a', 'Course')], slots: [], bookings: [], tz: MANILA });
  assert.equal(sheets.length, 1);
  assert.deepEqual(sheets[0].rows, []);
  assert.deepEqual(sheets[0].summary, { teeTimes: 0, bookable: 0, golfers: 0, spots: 0 });
});

test('spots fill one per booked golfer: paid first, then awaiting payment, then open', () => {
  const [sheet] = buildTeeSheets({
    courts: [court('a', 'Course')],
    slots: [slot('s', 'a', '07:00')],
    bookings: [
      booking('p', 's', 1, { status: 'pending_payment' }),
      booking('q', 's', 2),
      booking('gone', 's', 1, { status: 'cancelled' }),
    ],
    tz: MANILA,
  });
  const [row] = sheet.rows;
  assert.deepEqual(row.spots, ['paid', 'paid', 'pending', 'open']);
  assert.equal(row.booked, 3);
  assert.equal(row.capacity, 4);
  assert.deepEqual(row.parties.map((p) => p.id), ['p', 'q'], 'cancelled bookings are left out');
});

test('a tee time is open, partly booked, full or closed', () => {
  const [sheet] = buildTeeSheets({
    courts: [court('a', 'Course')],
    slots: [
      slot('open', 'a', '07:00'),
      slot('partly', 'a', '07:10'),
      slot('full', 'a', '07:20', { status: 'booked' }),
      slot('closed', 'a', '07:30', { status: 'closed' }),
      slot('cancelled', 'a', '07:40', { status: 'cancelled' }),
      slot('small', 'a', '07:50', { max_players: 2 }),
    ],
    bookings: [
      booking('b1', 'partly', 3),
      booking('b2', 'full', 2),
      booking('b3', 'full', 2, { status: 'completed' }),
      booking('b4', 'small', 2),
    ],
    tz: MANILA,
  });
  assert.deepEqual(
    sheet.rows.map((r) => [r.slotId, r.status, r.statusLabel]),
    [
      ['open', 'open', 'Open'],
      ['partly', 'partly_booked', 'Partly booked'],
      ['full', 'full', 'Full'],
      ['closed', 'closed', 'Closed'],
      ['cancelled', 'closed', 'Closed'],
      ['small', 'full', 'Full'],
    ],
  );
  assert.deepEqual(sheet.rows.at(-1).spots, ['paid', 'paid'], 'spots follow the tee time size');
  assert.deepEqual(sheet.summary, { teeTimes: 6, bookable: 2, golfers: 9, spots: 14 });
});

test('a tee time with no max players has the standard 4 spots', () => {
  const [sheet] = buildTeeSheets({
    courts: [court('a', 'Course')],
    slots: [slot('s', 'a', '07:00', { max_players: null })],
    bookings: [],
    tz: MANILA,
  });
  assert.equal(sheet.rows[0].capacity, 4);
  assert.deepEqual(sheet.rows[0].spots, ['open', 'open', 'open', 'open']);
});

test('parties show who booked, the party size and 9 or 18 holes', () => {
  const [sheet] = buildTeeSheets({
    courts: [court('a', 'Course')],
    slots: [slot('s', 'a', '07:00')],
    bookings: [
      booking('one', 's', 1, { holes: 9, captain: { display_name: 'Ana Reyes' } }),
      booking('two', 's', 2, { holes: 18, captain: null }),
      booking('old', 's', 1, { holes: undefined, captain: { display_name: null } }),
    ],
    tz: MANILA,
  });
  assert.deepEqual(
    sheet.rows[0].parties.map(({ name, partySize, partyLabel, holes, holesLabel, pending }) => ({
      name,
      partySize,
      partyLabel,
      holes,
      holesLabel,
      pending,
    })),
    [
      { name: 'Ana Reyes', partySize: 1, partyLabel: 'Single', holes: 9, holesLabel: '9 holes', pending: false },
      { name: 'Golfer', partySize: 2, partyLabel: 'Twosome', holes: 18, holesLabel: '18 holes', pending: false },
      { name: 'Golfer', partySize: 1, partyLabel: 'Single', holes: 18, holesLabel: '18 holes', pending: false },
    ],
  );
});

test('party and holes labels', () => {
  assert.deepEqual([1, 2, 3, 4, 5].map(partyLabel), ['Single', 'Twosome', 'Threesome', 'Foursome', '5 golfers']);
  assert.equal(holesLabel(9), '9 holes');
  assert.equal(holesLabel(18), '18 holes');
});

test('prices per golfer for 18 and 9 holes; no 9 hole price means none offered', () => {
  const [sheet] = buildTeeSheets({
    courts: [court('a', 'Course')],
    slots: [
      slot('both', 'a', '07:00'),
      slot('only18', 'a', '07:10', { price_per_player_9_cents: null }),
      slot('legacy', 'a', '07:20', { price_per_player_cents: null, price_cents: 180000, price_per_player_9_cents: undefined }),
    ],
    bookings: [],
    tz: MANILA,
  });
  assert.deepEqual(
    sheet.rows.map((r) => [r.slotId, r.price18Cents, r.price9Cents]),
    [
      ['both', 250000, 140000],
      ['only18', 250000, null],
      ['legacy', 180000, null],
    ],
  );
});

test('tee times are labelled in the venue timezone, with a marker where each hour starts', () => {
  const slots = [slot('a', 'c', '07:00'), slot('b', 'c', '07:50'), slot('c', 'c', '08:00'), slot('d', 'c', '08:10')];
  const [manila] = buildTeeSheets({ courts: [court('c', 'Course')], slots, bookings: [], tz: MANILA });
  assert.deepEqual(manila.rows.map((r) => clean(r.time)), ['7:00 AM', '7:50 AM', '8:00 AM', '8:10 AM']);
  assert.deepEqual(manila.rows.map((r) => r.hour), [7, 7, 8, 8]);
  assert.deepEqual(manila.rows.map((r) => r.newHour), [true, false, true, false]);

  const [sydney] = buildTeeSheets({ courts: [court('c', 'Course')], slots, bookings: [], tz: 'Australia/Sydney' });
  assert.deepEqual(sydney.rows.map((r) => clean(r.time)), ['10:00 AM', '10:50 AM', '11:00 AM', '11:10 AM']);
});

test('the device timezone never changes the labels', () => {
  const out = runInTz(
    'America/Los_Angeles',
    TEE_SHEET_URL,
    `
    const [sheet] = m.buildTeeSheets({
      courts: [{ id: 'c', name: 'Course', sport: 'golf', kind: 'course', metadata: null }],
      slots: [{ id: 's', court_id: 'c', starts_at: '2026-11-05T23:00:00.000Z', ends_at: '2026-11-05T23:10:00.000Z',
                status: 'available', max_players: 4, price_cents: 1, price_per_player_cents: 1, price_per_player_9_cents: null }],
      bookings: [],
      tz: 'Asia/Manila',
    });
    out.time = sheet.rows[0].time.replace(/\\s/g, ' ');
    out.hour = sheet.rows[0].hour;
  `,
  );
  assert.equal(out.time, '7:00 AM');
  assert.equal(out.hour, 7);
});

// The row is one button; its accessible name has to carry everything the row
// shows, since the spot markers are colour only (review of PR #12, finding 3).
test('a tee time row is announced with its parties, holes, payment state and prices', () => {
  const [sheet] = buildTeeSheets({
    courts: [court('a', 'Course')],
    slots: [slot('s', 'a', '07:00')],
    bookings: [
      booking('b1', 's', 2, { holes: 9, captain: { display_name: 'Ben Cruz' } }),
      booking('b2', 's', 1, { holes: 18, status: 'pending_payment', captain: { display_name: 'Carlo Santos' } }),
    ],
    tz: MANILA,
  });
  assert.equal(
    clean(teeTimeLabel(sheet.rows[0], 'PHP')),
    '7:00 AM, Partly booked, 3 of 4 spots taken. ' +
      'Ben Cruz, Twosome, 9 holes, paid. Carlo Santos, Single, 18 holes, unpaid. ' +
      'Per golfer: 18 holes ₱2,500, 9 holes ₱1,400. Edit tee time.',
  );
});

test('an empty tee time without a 9 hole price, and a closed one', () => {
  const [sheet] = buildTeeSheets({
    courts: [court('a', 'Course')],
    slots: [slot('open', 'a', '07:00', { price_per_player_9_cents: null }), slot('shut', 'a', '07:10', { status: 'closed' })],
    bookings: [],
    tz: MANILA,
  });
  assert.equal(
    clean(teeTimeLabel(sheet.rows[0], 'PHP')),
    '7:00 AM, Open, 0 of 4 spots taken. No bookings. Per golfer: 18 holes ₱2,500, 9 holes not offered. Edit tee time.',
  );
  assert.equal(
    clean(teeTimeLabel(sheet.rows[1], 'PHP')),
    '7:10 AM, Closed, 0 of 4 spots taken. No bookings. Per golfer: 18 holes ₱2,500, 9 holes ₱1,400. Edit tee time.',
  );
});

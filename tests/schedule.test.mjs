import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  courtBookingMode,
  courtGroups,
  groupLabel,
  seedWeek,
  buildTemplatePayload,
  emptyWeek,
  offersNineHoles,
  schedulePayload,
} from '../lib/schedule.ts';

const shared = { slotModel: { bookingMode: 'shared', pricingMode: 'per_player', teeIntervalMinutes: 8, maxPlayers: 4 } };
const exclusive = { slotModel: { bookingMode: 'exclusive', pricingMode: 'per_slot', defaultDurationMinutes: 60 } };
const court = (id, sport, metadata = null, active = true) => ({ id, sport, name: id, active, metadata });

const courts = [
  court('course', 'golf', shared),
  court('bay1', 'golf', exclusive),
  court('bay2', 'golf', exclusive),
  court('bay-off', 'golf', exclusive, false),
  court('t1', 'tennis'),
];
const label = (s) => ({ golf: 'Golf', tennis: 'Tennis' })[s] ?? s;

test('booking mode is read from slotModel exactly as the generator reads it', () => {
  assert.equal(courtBookingMode(court('a', 'golf', shared)), 'shared');
  assert.equal(courtBookingMode(court('a', 'golf', exclusive)), 'exclusive');
  assert.equal(courtBookingMode(court('a', 'golf', null)), 'exclusive');
  assert.equal(courtBookingMode(court('a', 'golf', { other: 1 })), 'exclusive');
});

test('a golf course and its range bays are separate groups; inactive courts are left out', () => {
  const groups = courtGroups(courts, ['tennis', 'golf']);
  assert.deepEqual(
    groups.map((g) => [g.key, g.courts.map((c) => c.id)]),
    [
      ['tennis:exclusive', ['t1']],
      ['golf:shared', ['course']],
      ['golf:exclusive', ['bay1', 'bay2']],
    ],
  );
});

test('labels only name the booking mode when a sport has more than one group', () => {
  const groups = courtGroups(courts, ['golf', 'tennis']);
  assert.deepEqual(groups.map((g) => groupLabel(g, groups, label)), ['Golf · tee times', 'Golf · bays', 'Tennis']);
});

test('seeding a group uses that group\'s templates only', () => {
  const templates = [
    { court_id: 'bay1', day_of_week: 1, start_time: '08:00:00', end_time: '22:00:00', slot_minutes: 60, price_cents: 40000, active: true },
    { court_id: 'course', day_of_week: 1, start_time: '06:00:00', end_time: '18:00:00', slot_minutes: 10, price_cents: 250000, active: true },
  ];
  const [course, bays] = courtGroups(courts, ['golf']);
  assert.deepEqual(seedWeek(course, templates)[1], { enabled: true, open: '06:00', close: '18:00', slotMinutes: 10, price: '2500', price9: '' });
  assert.deepEqual(seedWeek(bays, templates)[1], { enabled: true, open: '08:00', close: '22:00', slotMinutes: 60, price: '400', price9: '' });
  assert.equal(seedWeek(bays, templates)[2].enabled, false);
});

test('a group with no templates defaults to its own slot length', () => {
  const [course, bays] = courtGroups(courts, ['golf']);
  assert.equal(seedWeek(course, [])[1].slotMinutes, 8, 'tee interval from the course model');
  assert.equal(seedWeek(bays, [])[1].slotMinutes, 60);
});

const week = (patch) => {
  const w = emptyWeek(60);
  for (const [dow, p] of Object.entries(patch)) w[dow] = { ...w[dow], enabled: true, ...p };
  return w;
};

test('builds the RPC payload for enabled days only, prices in cents', () => {
  const r = buildTemplatePayload(week({ 1: { open: '09:00', close: '20:00', slotMinutes: 60, price: '1500' }, 0: { open: '07:00', close: '12:00', slotMinutes: 30, price: '0' } }));
  assert.deepEqual(r, {
    ok: true,
    templates: [
      { day_of_week: 1, start_time: '09:00', end_time: '20:00', slot_minutes: 60, price_cents: 150000 },
      { day_of_week: 0, start_time: '07:00', end_time: '12:00', slot_minutes: 30, price_cents: 0 },
    ],
  });
});

test('an empty week is a valid payload that clears the group', () => {
  assert.deepEqual(buildTemplatePayload(emptyWeek(60)), { ok: true, templates: [] });
});

test('rejects bad input before anything is saved, naming the day', () => {
  const cases = [
    [{ 2: { open: '20:00', close: '09:00' } }, 'Tue: closing time must be after opening time.'],
    [{ 2: { open: '09:00', close: '09:00' } }, 'Tue: closing time must be after opening time.'],
    [{ 3: { open: '09:00', close: '09:30', slotMinutes: 60 } }, 'Wed: slot length is longer than the opening hours.'],
    [{ 4: { slotMinutes: 4 } }, 'Thu: slot length must be a whole number from 5 to 1440 minutes.'],
    [{ 4: { slotMinutes: 7.5 } }, 'Thu: slot length must be a whole number from 5 to 1440 minutes.'],
    [{ 5: { price: '' } }, 'Fri: enter a price (0 for free).'],
    [{ 5: { price: '12a' } }, 'Fri: enter a price (0 for free).'],
    [{ 6: { open: '9am' } }, 'Sat: enter opening and closing times.'],
    [{ 6: { price: '21474837' } }, 'Sat: price is too high.'],
  ];
  for (const [patch, error] of cases) {
    assert.deepEqual(buildTemplatePayload(week(patch)), { ok: false, error }, error);
  }
});

test('reports the first problem in display order (Mon to Sun)', () => {
  const r = buildTemplatePayload(week({ 0: { price: '' }, 2: { open: '20:00', close: '09:00' } }));
  assert.deepEqual(r, { ok: false, error: 'Tue: closing time must be after opening time.' });
});

// ---------- C14: 9 hole price per golfer on a golf tee sheet ----------

test('only a golf tee sheet group takes a 9 hole price', () => {
  const [course, bays] = courtGroups(courts, ['golf']);
  const [tennis] = courtGroups([court('t1', 'tennis')]);
  const [sharedOther] = courtGroups([court('x', 'pickleball', shared)]);
  assert.equal(offersNineHoles(course), true);
  assert.equal(offersNineHoles(bays), false, 'existing range bays');
  assert.equal(offersNineHoles(tennis), false);
  assert.equal(offersNineHoles(sharedOther), false, 'shared but not golf');
});

test('an empty week has no 9 hole price', () => {
  assert.equal(emptyWeek(10)[1].price9, '');
});

test('seeding reads the template 9 hole price, blank when none', () => {
  const [course] = courtGroups(courts, ['golf']);
  const templates = [
    { court_id: 'course', day_of_week: 1, start_time: '06:00:00', end_time: '18:00:00', slot_minutes: 10, price_cents: 250000, price_9_cents: 140000, active: true },
    { court_id: 'course', day_of_week: 2, start_time: '06:00:00', end_time: '18:00:00', slot_minutes: 10, price_cents: 250000, price_9_cents: null, active: true },
  ];
  const w = seedWeek(course, templates);
  assert.equal(w[1].price9, '1400');
  assert.equal(w[2].price9, '');
});

test('a tee sheet payload carries price_9_cents, null when left blank', () => {
  const r = buildTemplatePayload(
    week({ 1: { open: '06:00', close: '18:00', slotMinutes: 10, price: '2500', price9: '1400' }, 2: { open: '06:00', close: '18:00', slotMinutes: 10, price: '2500', price9: '' } }),
    { ninePrice: true },
  );
  assert.deepEqual(r, {
    ok: true,
    templates: [
      { day_of_week: 1, start_time: '06:00', end_time: '18:00', slot_minutes: 10, price_cents: 250000, price_9_cents: 140000 },
      { day_of_week: 2, start_time: '06:00', end_time: '18:00', slot_minutes: 10, price_cents: 250000, price_9_cents: null },
    ],
  });
});

test('other groups never send a 9 hole price, whatever the form holds', () => {
  const r = buildTemplatePayload(week({ 1: { open: '08:00', close: '22:00', slotMinutes: 60, price: '400', price9: '200' } }));
  assert.deepEqual(r, { ok: true, templates: [{ day_of_week: 1, start_time: '08:00', end_time: '22:00', slot_minutes: 60, price_cents: 40000 }] });
});

test('a bad 9 hole price is rejected before anything is saved, naming the day', () => {
  assert.deepEqual(buildTemplatePayload(week({ 3: { price9: '9a' } }), { ninePrice: true }), {
    ok: false,
    error: 'Wed: enter a 9 hole price, or leave it blank to offer 18 holes only.',
  });
  assert.deepEqual(buildTemplatePayload(week({ 3: { price9: '21474837' } }), { ninePrice: true }), {
    ok: false,
    error: 'Wed: 9 hole price is too high.',
  });
});

// What the schedule editor saves for a group, review of PR #12 finding 1:
// dropping the 9 hole price from a golf tee sheet must fail here.
test('saving a golf tee sheet group sends each day\'s 9 hole price', () => {
  const [course, bays] = courtGroups(courts, ['golf']);
  const w = week({ 1: { open: '06:00', close: '18:00', slotMinutes: 10, price: '2500', price9: '1400' }, 2: { open: '06:00', close: '18:00', slotMinutes: 10, price: '2500', price9: '' } });
  assert.deepEqual(schedulePayload(course, w), {
    ok: true,
    templates: [
      { day_of_week: 1, start_time: '06:00', end_time: '18:00', slot_minutes: 10, price_cents: 250000, price_9_cents: 140000 },
      { day_of_week: 2, start_time: '06:00', end_time: '18:00', slot_minutes: 10, price_cents: 250000, price_9_cents: null },
    ],
  });
  assert.deepEqual(schedulePayload(bays, w), {
    ok: true,
    templates: [
      { day_of_week: 1, start_time: '06:00', end_time: '18:00', slot_minutes: 10, price_cents: 250000 },
      { day_of_week: 2, start_time: '06:00', end_time: '18:00', slot_minutes: 10, price_cents: 250000 },
    ],
  }, 'range bays never send one');
});

test('a bad 9 hole price stops a golf tee sheet save', () => {
  const [course] = courtGroups(courts, ['golf']);
  assert.equal(schedulePayload(course, week({ 1: { price9: '1.5' } })).ok, false);
});

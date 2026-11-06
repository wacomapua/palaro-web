import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SPORT_CONFIGS, courtSlotModel, materialisePreset, slotModelForPreset } from '../lib/sport-presets.ts';

const golf = SPORT_CONFIGS.find((c) => c.sport === 'golf');

test('golf offers one preset: a course with one tee sheet', () => {
  assert.deepEqual(golf.presets.map((p) => p.id), ['golf-18']);
  const [course] = golf.presets;
  assert.equal(course.variableCount, undefined, 'no "N bays" counter');
  assert.deepEqual(
    materialisePreset(course).map((n) => n.kind),
    ['course'],
    'one course node, no front and back nine split',
  );
  assert.deepEqual(slotModelForPreset(course), {
    bookingMode: 'shared',
    pricingMode: 'per_player',
    defaultDurationMinutes: 10,
    teeIntervalMinutes: 10,
    maxPlayers: 4,
  });
});

test('no golf preset offers driving range bays or a front and back nine', () => {
  for (const p of golf.presets) {
    assert.doesNotMatch(`${p.label} ${p.description}`, /driving range|range bay|front 9|back 9/i, p.id);
  }
});

test('the course preset says golfers choose 18 or 9 holes', () => {
  assert.match(golf.presets[0].description, /18/);
  assert.match(golf.presets[0].description, /9 hole/);
});

// Courts made from the presets that are no longer offered keep the slot model
// stored on them, so their calendar and editors behave as before.
const court = (sport, kind, metadata) => ({ sport, kind, metadata });

test('an existing driving range bay keeps its exclusive hourly model', () => {
  const bay = court('golf', 'court', {
    slotModel: { bookingMode: 'exclusive', pricingMode: 'per_slot', defaultDurationMinutes: 60 },
  });
  assert.deepEqual(courtSlotModel(bay), {
    bookingMode: 'exclusive',
    pricingMode: 'per_slot',
    defaultDurationMinutes: 60,
    teeIntervalMinutes: undefined,
    maxPlayers: undefined,
  });
});

test('an existing Front 9 or Back 9 course keeps its tee sheet model', () => {
  const front = court('golf', 'course', {
    slotModel: { bookingMode: 'shared', pricingMode: 'per_player', defaultDurationMinutes: 10, teeIntervalMinutes: 10, maxPlayers: 4 },
  });
  assert.deepEqual(courtSlotModel(front), {
    bookingMode: 'shared',
    pricingMode: 'per_player',
    defaultDurationMinutes: 10,
    teeIntervalMinutes: 10,
    maxPlayers: 4,
  });
});

test('a golf course with no stored model is a tee sheet; anything else is exclusive', () => {
  assert.equal(courtSlotModel(court('golf', 'course', null)).bookingMode, 'shared');
  assert.equal(courtSlotModel(court('golf', 'course', null)).maxPlayers, 4);
  assert.equal(courtSlotModel(court('golf', 'court', null)).bookingMode, 'exclusive');
  assert.equal(courtSlotModel(court('tennis', 'court', null)).bookingMode, 'exclusive');
  assert.equal(courtSlotModel(null).defaultDurationMinutes, 120);
});

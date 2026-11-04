import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  addDaysYmd,
  dayRangeUtc,
  formatYmd,
  tzParts,
  ymdInTz,
  zonedTimeToUtc,
} from '../lib/tz.ts';

const HOUR = 3_600_000;
const TZ_URL = new URL('../lib/tz.ts', import.meta.url).href;

// TZ is read when a process starts, so behaviour under another process
// timezone is checked in a child node. The child also reports the zone it
// resolved, so a typo here cannot make the test pass vacuously.
function runInTz(tz, body) {
  const code = `
    const tz = await import(${JSON.stringify(TZ_URL)});
    const out = { resolved: Intl.DateTimeFormat().resolvedOptions().timeZone };
    ${body}
    process.stdout.write(JSON.stringify(out));
  `;
  const r = spawnSync(process.execPath, ['--no-warnings', '--input-type=module', '-e', code], {
    env: { ...process.env, TZ: tz },
    encoding: 'utf8',
  });
  assert.equal(r.status, 0, r.stderr);
  const out = JSON.parse(r.stdout);
  assert.equal(out.resolved, tz, 'child process did not pick up TZ');
  return out;
}

const hours = ({ start, end }) => (end.getTime() - start.getTime()) / HOUR;

test('dayRangeUtc spans 24 hours on ordinary days', () => {
  for (const tz of ['Asia/Manila', 'Australia/Sydney', 'Europe/London', 'America/New_York']) {
    assert.equal(hours(dayRangeUtc('2026-06-15', tz)), 24, tz);
  }
});

test('dayRangeUtc is 23 or 25 hours on DST transition days', () => {
  const cases = [
    ['Australia/Sydney', '2026-04-05', 25], // AEDT to AEST
    ['Australia/Sydney', '2026-10-04', 23], // AEST to AEDT
    ['Europe/London', '2026-03-29', 23], // GMT to BST
    ['Europe/London', '2026-10-25', 25], // BST to GMT
    ['America/New_York', '2026-03-08', 23], // EST to EDT
    ['America/New_York', '2026-11-01', 25], // EDT to EST
  ];
  for (const [tz, ymd, expected] of cases) {
    assert.equal(hours(dayRangeUtc(ymd, tz)), expected, `${tz} ${ymd}`);
  }
});

test('dayRangeUtc starts at venue midnight', () => {
  assert.equal(dayRangeUtc('2026-05-30', 'Asia/Manila').start.toISOString(), '2026-05-29T16:00:00.000Z');
  const ny = dayRangeUtc('2026-11-01', 'America/New_York');
  assert.equal(ny.start.toISOString(), '2026-11-01T04:00:00.000Z');
  assert.equal(ny.end.toISOString(), '2026-11-02T05:00:00.000Z');
  const syd = dayRangeUtc('2026-10-04', 'Australia/Sydney');
  assert.equal(syd.start.toISOString(), '2026-10-03T14:00:00.000Z');
  assert.equal(syd.end.toISOString(), '2026-10-04T13:00:00.000Z');
});

test('zonedTimeToUtc matches known instants', () => {
  const cases = [
    [[2026, 5, 30, 7, 0, 'Asia/Manila'], '2026-05-29T23:00:00.000Z'],
    [[2026, 1, 1, 0, 0, 'Asia/Manila'], '2025-12-31T16:00:00.000Z'],
    [[2026, 3, 8, 1, 59, 'America/New_York'], '2026-03-08T06:59:00.000Z'],
    [[2026, 3, 8, 3, 0, 'America/New_York'], '2026-03-08T07:00:00.000Z'],
    [[2026, 10, 25, 2, 0, 'Europe/London'], '2026-10-25T02:00:00.000Z'],
    [[2026, 4, 5, 3, 0, 'Australia/Sydney'], '2026-04-04T17:00:00.000Z'],
  ];
  for (const [args, iso] of cases) {
    assert.equal(zonedTimeToUtc(...args).toISOString(), iso, args.join(' '));
  }
});

// Wall times that do not exist because clocks jump forward.
const GAPS = {
  'Australia/Sydney': { ymd: '2026-10-04', hour: 2 },
  'Europe/London': { ymd: '2026-03-29', hour: 1 },
  'America/New_York': { ymd: '2026-03-08', hour: 2 },
};

test('zonedTimeToUtc round trips every half hour wall time', () => {
  const zones = {
    'Asia/Manila': ['2026-01-01', '2026-05-30', '2026-12-31'],
    'Australia/Sydney': ['2026-04-05', '2026-10-04', '2026-06-15'],
    'Europe/London': ['2026-03-29', '2026-10-25', '2026-06-15'],
    'America/New_York': ['2026-03-08', '2026-11-01', '2026-06-15'],
  };
  for (const [tz, days] of Object.entries(zones)) {
    for (const ymd of days) {
      const [y, mo, d] = ymd.split('-').map(Number);
      for (let h = 0; h < 24; h++) {
        if (GAPS[tz]?.ymd === ymd && GAPS[tz].hour === h) continue;
        for (const mi of [0, 30]) {
          const p = tzParts(zonedTimeToUtc(y, mo, d, h, mi, tz), tz);
          assert.deepEqual(
            [p.year, p.month, p.day, p.hour, p.minute],
            [y, mo, d, h, mi],
            `${tz} ${ymd} ${h}:${mi}`,
          );
        }
      }
    }
  }
});

test('zonedTimeToUtc picks one of the two instants in a repeated hour', () => {
  const t = zonedTimeToUtc(2026, 11, 1, 1, 30, 'America/New_York').toISOString();
  assert.ok(['2026-11-01T05:30:00.000Z', '2026-11-01T06:30:00.000Z'].includes(t), t);
});

test('ymdInTz flips exactly at venue midnight', () => {
  const at = (iso, tz) => ymdInTz(new Date(iso), tz);
  assert.equal(at('2026-05-29T16:00:00.000Z', 'Asia/Manila'), '2026-05-30');
  assert.equal(at('2026-05-29T15:59:59.999Z', 'Asia/Manila'), '2026-05-29');
  assert.equal(at('2026-11-01T04:00:00.000Z', 'America/New_York'), '2026-11-01');
  assert.equal(at('2026-11-01T03:59:59.999Z', 'America/New_York'), '2026-10-31');
  for (const [tz, ymd] of [
    ['Australia/Sydney', '2026-10-04'],
    ['Europe/London', '2026-10-25'],
    ['America/New_York', '2026-03-08'],
  ]) {
    const { start, end } = dayRangeUtc(ymd, tz);
    assert.equal(ymdInTz(start, tz), ymd, `${tz} start`);
    assert.equal(ymdInTz(new Date(end.getTime() - 1), tz), ymd, `${tz} end`);
    assert.equal(ymdInTz(end, tz), addDaysYmd(ymd, 1), `${tz} next`);
  }
});

test('addDaysYmd crosses year end and leap days', () => {
  assert.equal(addDaysYmd('2026-12-31', 1), '2027-01-01');
  assert.equal(addDaysYmd('2027-01-01', -1), '2026-12-31');
  assert.equal(addDaysYmd('2026-12-28', 7), '2027-01-04');
  assert.equal(addDaysYmd('2028-02-28', 1), '2028-02-29');
  assert.equal(addDaysYmd('2028-02-29', 1), '2028-03-01');
  assert.equal(addDaysYmd('2028-03-01', -1), '2028-02-29');
  assert.equal(addDaysYmd('2027-02-28', 1), '2027-03-01');
  assert.equal(addDaysYmd('2026-05-30', 0), '2026-05-30');
});

test('formatYmd renders the given calendar date', () => {
  assert.equal(formatYmd('2026-05-30'), 'Sat, May 30, 2026');
  assert.equal(formatYmd('2028-02-29'), 'Tue, Feb 29, 2028');
});

test('formatYmd keeps the same date in processes far ahead of or behind UTC', () => {
  for (const zone of ['Pacific/Auckland', 'Pacific/Kiritimati', 'Pacific/Pago_Pago']) {
    const out = runInTz(zone, `out.a = tz.formatYmd('2026-05-30'); out.b = tz.formatYmd('2026-12-31');`);
    assert.equal(out.a, 'Sat, May 30, 2026', zone);
    assert.equal(out.b, 'Thu, Dec 31, 2026', zone);
  }
});

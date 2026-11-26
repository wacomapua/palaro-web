import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as format from '../lib/format.ts';
import { runInTz } from './run-in-tz.mjs';

const FORMAT_URL = new URL('../lib/format.ts', import.meta.url).href;

// 7:00 AM Saturday 30 May in Manila, 11:00 PM Friday 29 May in UTC.
const MANILA_7AM = '2026-05-29T23:00:00Z';

test('formatTime renders the time in the given timezone', () => {
  assert.equal(format.formatTime(MANILA_7AM, 'Asia/Manila'), '7:00 AM');
  assert.equal(format.formatTime(new Date(MANILA_7AM), 'America/New_York'), '7:00 PM');
});

test('formatDate renders the day in the given timezone', () => {
  assert.equal(format.formatDate(MANILA_7AM, 'Asia/Manila'), 'Sat, May 30');
  assert.equal(format.formatDate(new Date(MANILA_7AM), 'America/New_York'), 'Fri, May 29');
});

test('formatDateTime renders day and time in the given timezone', () => {
  assert.equal(format.formatDateTime(MANILA_7AM, 'Asia/Manila'), 'Sat, May 30 · 7:00 AM');
  // 06:30Z on 1 Nov is 1:30 AM EST, after New York falls back.
  assert.equal(
    format.formatDateTime('2026-11-01T06:30:00Z', 'America/New_York'),
    'Sun, Nov 1 · 1:30 AM',
  );
});

test('formatDateTime ignores the server timezone', () => {
  for (const zone of ['UTC', 'America/Los_Angeles', 'Pacific/Kiritimati']) {
    const out = runInTz(zone, FORMAT_URL, `out.s = m.formatDateTime('${MANILA_7AM}', 'Asia/Manila');`);
    assert.equal(out.s, 'Sat, May 30 · 7:00 AM', zone);
  }
});

test('formatYmdRange renders date only columns as written', () => {
  assert.equal(format.formatYmdRange('2026-05-25', '2026-05-31'), 'May 25–May 31');
  assert.equal(format.formatYmdRange('2026-12-28', '2027-01-03'), 'Dec 28–Jan 3');
});

test('formatYmdRange ignores the server timezone', () => {
  for (const zone of ['America/Los_Angeles', 'Pacific/Pago_Pago', 'Pacific/Kiritimati']) {
    const out = runInTz(zone, FORMAT_URL, `out.s = m.formatYmdRange('2026-05-25', '2026-05-31');`);
    assert.equal(out.s, 'May 25–May 31', zone);
  }
});

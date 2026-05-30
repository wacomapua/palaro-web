// Timezone helpers. A venue operates in a fixed local timezone
// (venues.timezone), so "Monday 9am" means 9am AT THE VENUE regardless of where
// the owner's browser or the server happens to be. We anchor all slot/day math
// to that zone instead of the server's (UTC) or the browser's local time —
// which is what caused slots to land a day early.
//
// Implemented with Intl (no extra dependency). Exact for fixed-offset zones
// like Asia/Manila; within DST zones it's accurate except possibly during the
// brief transition window, which is fine for venue day buckets.

export interface ZonedParts {
  year: number;
  month: number; // 1-12
  day: number;
  hour: number; // 0-23
  minute: number;
  second: number;
  weekday: number; // 0 = Sunday … 6 = Saturday (matches Date.getDay / templates)
}

const WEEKDAY: Record<string, number> = {
  Sun: 0,
  Mon: 1,
  Tue: 2,
  Wed: 3,
  Thu: 4,
  Fri: 5,
  Sat: 6,
};

// Wall-clock parts of an instant, as seen in `tz`.
export function tzParts(date: Date, tz: string): ZonedParts {
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone: tz,
    hour12: false,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    weekday: 'short',
  });
  const m: Record<string, string> = {};
  for (const p of dtf.formatToParts(date)) m[p.type] = p.value;
  return {
    year: Number(m.year),
    month: Number(m.month),
    day: Number(m.day),
    hour: Number(m.hour) % 24, // Intl can emit "24" at midnight
    minute: Number(m.minute),
    second: Number(m.second),
    weekday: WEEKDAY[m.weekday] ?? 0,
  };
}

// How many ms `tz` is ahead of UTC at the given instant.
function tzOffsetMs(date: Date, tz: string): number {
  const p = tzParts(date, tz);
  const asUTC = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  return asUTC - date.getTime();
}

// The UTC instant for a wall-clock time written in `tz`.
export function zonedTimeToUtc(
  year: number,
  month: number, // 1-12
  day: number,
  hour: number,
  minute: number,
  tz: string,
): Date {
  const guess = Date.UTC(year, month - 1, day, hour, minute, 0);
  // One refinement pass settles DST edges.
  const offset = tzOffsetMs(new Date(guess), tz);
  const refined = tzOffsetMs(new Date(guess - offset), tz);
  return new Date(guess - refined);
}

// [start, end) UTC instants for a venue-local calendar day "YYYY-MM-DD".
export function dayRangeUtc(ymd: string, tz: string): { start: Date; end: Date } {
  const [y, mo, d] = ymd.split('-').map(Number);
  const start = zonedTimeToUtc(y, mo, d, 0, 0, tz);
  const [ny, nmo, nd] = addDaysYmd(ymd, 1).split('-').map(Number);
  const end = zonedTimeToUtc(ny, nmo, nd, 0, 0, tz);
  return { start, end };
}

// "YYYY-MM-DD" of an instant as seen in `tz` (e.g. "today at the venue").
export function ymdInTz(date: Date, tz: string): string {
  const p = tzParts(date, tz);
  return `${p.year}-${pad(p.month)}-${pad(p.day)}`;
}

// Calendar-day arithmetic on a "YYYY-MM-DD" string (timezone-agnostic).
export function addDaysYmd(ymd: string, delta: number): string {
  const [y, mo, d] = ymd.split('-').map(Number);
  const t = Date.UTC(y, mo - 1, d) + delta * 86_400_000;
  const dt = new Date(t);
  return `${dt.getUTCFullYear()}-${pad(dt.getUTCMonth() + 1)}-${pad(dt.getUTCDate())}`;
}

// Decimal hour-of-day (e.g. 9.5 for 9:30) of an instant in `tz` — for laying
// slots out on the calendar grid.
export function hourInTz(date: Date, tz: string): number {
  const p = tzParts(date, tz);
  return p.hour + p.minute / 60;
}

export function formatTimeInTz(date: Date, tz: string): string {
  return new Intl.DateTimeFormat('en-US', {
    timeZone: tz,
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
  }).format(date);
}

// A long human date for a "YYYY-MM-DD" (rendered tz-agnostically at noon UTC to
// avoid any edge slippage).
export function formatYmd(ymd: string): string {
  const [y, mo, d] = ymd.split('-').map(Number);
  return new Intl.DateTimeFormat('en-US', {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  }).format(new Date(Date.UTC(y, mo - 1, d, 12)));
}

function pad(n: number): string {
  return String(n).padStart(2, '0');
}

// A small, curated timezone list for the venue picker (extend as needed).
export const COMMON_TIMEZONES: { value: string; label: string }[] = [
  { value: 'Asia/Manila', label: 'Manila (PHT, UTC+8)' },
  { value: 'Asia/Singapore', label: 'Singapore (UTC+8)' },
  { value: 'Asia/Hong_Kong', label: 'Hong Kong (UTC+8)' },
  { value: 'Asia/Tokyo', label: 'Tokyo (UTC+9)' },
  { value: 'Asia/Bangkok', label: 'Bangkok (UTC+7)' },
  { value: 'Asia/Jakarta', label: 'Jakarta (UTC+7)' },
  { value: 'Asia/Dubai', label: 'Dubai (UTC+4)' },
  { value: 'Australia/Sydney', label: 'Sydney (UTC+10/11)' },
  { value: 'Australia/Brisbane', label: 'Brisbane (UTC+10)' },
  { value: 'Europe/London', label: 'London (UTC+0/1)' },
  { value: 'America/New_York', label: 'New York (UTC−5/4)' },
  { value: 'America/Los_Angeles', label: 'Los Angeles (UTC−8/7)' },
];

// Money + time formatters. Mirrors team-manager/src/lib/format.ts so both
// apps render the same numbers identically.

export function formatMoney(cents: number, currency = 'PHP'): string {
  // Intl 'narrowSymbol' gives ₱ instead of "PHP" while still locale-aware.
  return new Intl.NumberFormat('en-PH', {
    style: 'currency',
    currency,
    currencyDisplay: 'narrowSymbol',
    minimumFractionDigits: 0,
    maximumFractionDigits: 0,
  }).format(cents / 100);
}

export function platformFeeCents(amount: number, pct: number): number {
  return Math.round((amount * pct) / 100);
}

// Slot times and dates are shown in the venue's timezone (venues.timezone),
// never the server's or the browser's, so every caller passes `tz`.
export function formatTime(d: Date | string, tz: string): string {
  const date = typeof d === 'string' ? new Date(d) : d;
  return new Intl.DateTimeFormat('en-PH', {
    timeZone: tz,
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
  }).format(date);
}

export function formatDate(d: Date | string, tz: string): string {
  const date = typeof d === 'string' ? new Date(d) : d;
  return new Intl.DateTimeFormat('en-PH', {
    timeZone: tz,
    weekday: 'short',
    month: 'short',
    day: 'numeric',
  }).format(date);
}

export function formatDateTime(d: Date | string, tz: string): string {
  return `${formatDate(d, tz)} · ${formatTime(d, tz)}`;
}

// Short range label for two Postgres `date` values. They are calendar dates
// with no instant attached, so they are formatted in UTC and never shift with
// the server's timezone.
export function formatYmdRange(startYmd: string, endYmd: string): string {
  return `${formatShortYmd(startYmd)}–${formatShortYmd(endYmd)}`;
}

function formatShortYmd(ymd: string): string {
  const [y, mo, d] = ymd.split('-').map(Number);
  return new Intl.DateTimeFormat('en-PH', {
    timeZone: 'UTC',
    month: 'short',
    day: 'numeric',
  }).format(new Date(Date.UTC(y, mo - 1, d, 12)));
}

export function durationMinutes(start: Date | string, end: Date | string): number {
  const s = typeof start === 'string' ? new Date(start) : start;
  const e = typeof end === 'string' ? new Date(end) : end;
  return Math.round((e.getTime() - s.getTime()) / 60_000);
}

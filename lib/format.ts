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

export function formatTime(d: Date | string): string {
  const date = typeof d === 'string' ? new Date(d) : d;
  return new Intl.DateTimeFormat('en-PH', {
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
  }).format(date);
}

export function formatDate(d: Date | string): string {
  const date = typeof d === 'string' ? new Date(d) : d;
  return new Intl.DateTimeFormat('en-PH', {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
  }).format(date);
}

export function formatDateTime(d: Date | string): string {
  return `${formatDate(d)} · ${formatTime(d)}`;
}

export function durationMinutes(start: Date | string, end: Date | string): number {
  const s = typeof start === 'string' ? new Date(start) : start;
  const e = typeof end === 'string' ? new Date(end) : end;
  return Math.round((e.getTime() - s.getTime()) / 60_000);
}

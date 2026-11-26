// Closure form and result logic for /settings/schedule, kept free of React
// so `node --test` can import it directly. Closures are created only through
// the create_venue_closure RPC, which closes the slots, cancels bookings and
// queues full refunds for the paid ones in one transaction.

import { zonedTimeToUtc } from './tz.ts';
import { formatMoney } from './format.ts';

export interface ClosureForm {
  courtId: string; // '' = whole venue
  start: string; // datetime-local, venue wall time
  end: string;
  reason: string;
}

export interface ClosureArgs {
  _court_id: string | null;
  _starts_at: string;
  _ends_at: string;
  _reason: string | null;
}

export interface ClosureResult {
  closureId: string;
  closedSlots: number;
  refundedBookingIds: string[];
}

export interface AffectedBooking {
  id: string;
  total_cents: number;
  party_size: number;
  captain: { display_name: string | null; email: string | null } | null;
  slot: { starts_at: string; ends_at: string; court: { name: string } | null } | null;
}

// Parse a datetime-local value ("YYYY-MM-DDTHH:MM"), read as venue-local
// wall time, into a UTC instant.
export function localInputToUtc(value: string, tz: string): Date | null {
  if (!value) return null;
  const [d, t] = value.split('T');
  if (!d || !t) return null;
  const [y, mo, day] = d.split('-').map(Number);
  const [h, mi] = t.split(':').map(Number);
  if ([y, mo, day, h, mi].some((n) => !Number.isFinite(n))) return null;
  return zonedTimeToUtc(y, mo, day, h, mi, tz);
}

export function closureRequest(
  form: ClosureForm,
  tz: string,
  now: Date = new Date(),
): { ok: true; args: ClosureArgs } | { ok: false; error: string } {
  const start = localInputToUtc(form.start, tz);
  const end = localInputToUtc(form.end, tz);
  if (!start || !end) return { ok: false, error: 'Pick a start and end.' };
  if (end <= start) return { ok: false, error: 'End must be after start.' };
  if (end <= now) return { ok: false, error: 'That window has already ended.' };
  return {
    ok: true,
    args: {
      _court_id: form.courtId || null,
      _starts_at: start.toISOString(),
      _ends_at: end.toISOString(),
      _reason: form.reason.trim() || null,
    },
  };
}

interface ClosureRow {
  closure_id: string;
  closed_slot_count: number;
  refunded_booking_ids: string[] | null;
}

// supabase-js returns a table function's rows as an array.
export function readClosureResult(data: unknown): ClosureResult | null {
  const row = (Array.isArray(data) ? data[0] : data) as ClosureRow | undefined;
  if (!row || typeof row !== 'object' || !row.closure_id) return null;
  return {
    closureId: row.closure_id,
    closedSlots: row.closed_slot_count ?? 0,
    refundedBookingIds: row.refunded_booking_ids ?? [],
  };
}

function plural(n: number, one: string, many: string): string {
  return `${n} ${n === 1 ? one : many}`;
}

export function closureSummary(r: Pick<ClosureResult, 'closedSlots' | 'refundedBookingIds'>): string {
  const refunded = r.refundedBookingIds.length;
  if (r.closedSlots === 0 && refunded === 0) return 'Closure added. There were no open slots in that window.';
  const closed = `Closed ${plural(r.closedSlots, 'slot', 'slots')}`;
  if (refunded === 0) return `Closure added. ${closed}.`;
  const cancelled = refunded === 1 ? '1 paid booking with a full refund' : `${refunded} paid bookings with full refunds`;
  return `Closure added. ${closed} and cancelled ${cancelled}.`;
}

// The refunds are already queued in the database; the edge function only
// sends them. A failed call is worth telling the owner about, not blocking.
export function refundWarning(error: { message?: string } | null): string | null {
  if (!error) return null;
  const detail = error.message ? ` (${error.message})` : '';
  return `Refunds are queued, but processing did not start${detail}. They will go out the next time refunds are processed.`;
}

export function fmtRange(startsIso: string, endsIso: string, tz: string): string {
  const f = new Intl.DateTimeFormat('en-US', {
    timeZone: tz,
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  });
  return `${f.format(new Date(startsIso))} → ${f.format(new Date(endsIso))}`;
}

export function affectedBookingLine(b: AffectedBooking, tz: string, currency: string) {
  const name = b.captain?.display_name || b.captain?.email || 'Player';
  return {
    id: b.id,
    who: b.party_size > 1 ? `${name} (${b.party_size} players)` : name,
    when: b.slot ? fmtRange(b.slot.starts_at, b.slot.ends_at, tz) : '',
    where: b.slot?.court?.name ?? '',
    refund: formatMoney(b.total_cents, currency),
  };
}

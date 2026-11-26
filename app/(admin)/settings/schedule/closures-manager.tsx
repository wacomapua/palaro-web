'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { Trash2, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { createClient } from '@/lib/supabase/client';
import {
  affectedBookingLine,
  closureRequest,
  closureSummary,
  fmtRange,
  readClosureResult,
  refundWarning,
  type AffectedBooking,
} from '@/lib/closures';
import type { VenueSport } from '@/lib/types/db';

interface Court {
  id: string;
  sport: VenueSport;
  name: string;
  active: boolean;
}
interface Closure {
  id: string;
  court_id: string | null;
  starts_at: string;
  ends_at: string;
  reason: string | null;
}
interface Outcome {
  summary: string;
  bookings: ReturnType<typeof affectedBookingLine>[];
  warning: string | null;
}

export function ClosuresManager({
  venueId,
  timezone,
  currency,
  courts,
  closures,
}: {
  venueId: string;
  timezone: string;
  currency: string;
  courts: Court[];
  closures: Closure[];
}) {
  const router = useRouter();
  const [courtId, setCourtId] = useState<string>(''); // '' = whole venue
  const [startVal, setStartVal] = useState('');
  const [endVal, setEndVal] = useState('');
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [outcome, setOutcome] = useState<Outcome | null>(null);

  const courtName = (id: string | null) =>
    id === null ? 'Whole venue' : courts.find((c) => c.id === id)?.name ?? 'Court';

  async function addClosure() {
    setError(null);
    setOutcome(null);
    const req = closureRequest({ courtId, start: startVal, end: endVal, reason }, timezone);
    if (!req.ok) {
      setError(req.error);
      return;
    }
    setBusy(true);
    const supabase = createClient();

    // One RPC does it all in one transaction: closure row, slots closed,
    // bookings cancelled, full refunds queued for the paid ones.
    const { data, error: rpcErr } = await supabase.rpc('create_venue_closure', {
      _venue_id: venueId,
      ...req.args,
    });
    const result = rpcErr ? null : readClosureResult(data);
    if (rpcErr || !result) {
      setError(rpcErr?.message ?? 'The closure was not saved. Please try again.');
      setBusy(false);
      return;
    }

    let warning: string | null = null;
    let bookings: Outcome['bookings'] = [];
    if (result.refundedBookingIds.length > 0) {
      // Send the queued refunds now. If this fails they stay queued.
      const { error: fnErr } = await supabase.functions.invoke('payments-process-refunds');
      warning = refundWarning(fnErr);

      const { data: rows, error: listErr } = await supabase
        .from('venue_bookings')
        .select(
          'id, total_cents, party_size, captain:profiles!captain_user_id(display_name, email), slot:venue_slots(starts_at, ends_at, court:venue_courts(name))',
        )
        .in('id', result.refundedBookingIds);
      if (listErr) {
        warning = [warning, `Could not load the cancelled bookings (${listErr.message}); see Bookings.`]
          .filter(Boolean)
          .join(' ');
      }
      bookings = ((rows ?? []) as unknown as AffectedBooking[]).map((b) =>
        affectedBookingLine(b, timezone, currency),
      );
    }

    setOutcome({ summary: closureSummary(result), bookings, warning });
    setBusy(false);
    setStartVal('');
    setEndVal('');
    setReason('');
    router.refresh();
  }

  async function remove(id: string) {
    if (!confirm('Remove this closure? Slots it closed stay closed, and cancelled bookings stay cancelled.')) return;
    setBusy(true);
    setError(null);
    const supabase = createClient();
    const { error: delErr } = await supabase.from('venue_closures').delete().eq('id', id);
    setBusy(false);
    if (delErr) {
      setError(delErr.message);
      return;
    }
    router.refresh();
  }

  return (
    <div className="space-y-5">
      {/* Result of the last closure */}
      {outcome && (
        <div className="card-base p-4">
          <div className="flex items-start justify-between gap-3">
            <p className="text-sm text-ink">{outcome.summary}</p>
            <Button variant="ghost" size="icon" onClick={() => setOutcome(null)} title="Dismiss">
              <X className="h-3.5 w-3.5" />
            </Button>
          </div>
          {outcome.bookings.length > 0 && (
            <ul className="mt-3 divide-y divide-line/40 text-sm">
              {outcome.bookings.map((b) => (
                <li key={b.id} className="flex flex-wrap items-center justify-between gap-2 py-2">
                  <div className="min-w-0">
                    <p className="text-ink">{b.who}</p>
                    <p className="text-xs text-ink-dim">
                      {b.when}
                      {b.where && ` · ${b.where}`}
                    </p>
                  </div>
                  <Badge tone="warn">Refund {b.refund}</Badge>
                </li>
              ))}
            </ul>
          )}
          {outcome.warning && <p className="mt-3 text-xs text-warn">{outcome.warning}</p>}
        </div>
      )}

      {/* Existing */}
      {closures.length > 0 && (
        <ul className="card-base divide-y divide-line/40 p-0">
          {closures.map((c) => (
            <li key={c.id} className="flex items-center justify-between gap-3 px-4 py-3">
              <div className="min-w-0">
                <p className="text-sm text-ink">
                  {fmtRange(c.starts_at, c.ends_at, timezone)}
                  {c.reason && <span className="text-ink-dim"> · {c.reason}</span>}
                </p>
                <Badge tone="neutral" className="mt-1">{courtName(c.court_id)}</Badge>
              </div>
              <Button variant="ghost" size="icon" disabled={busy} onClick={() => remove(c.id)} title="Remove">
                <Trash2 className="h-3.5 w-3.5" />
              </Button>
            </li>
          ))}
        </ul>
      )}

      {/* Add */}
      <div className="card-base p-5">
        <p className="mb-3 text-sm font-medium text-ink">Block off a date</p>
        <div className="grid gap-3 sm:grid-cols-2">
          <div className="space-y-1.5">
            <Label htmlFor="closure-court">Applies to</Label>
            <select
              id="closure-court"
              className="input-base"
              value={courtId}
              onChange={(e) => setCourtId(e.target.value)}
            >
              <option value="">Whole venue</option>
              {courts.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </select>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="closure-reason">Reason (optional)</Label>
            <Input
              id="closure-reason"
              placeholder="Maintenance, private event…"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
            />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="closure-start">From</Label>
            <Input id="closure-start" type="datetime-local" value={startVal} onChange={(e) => setStartVal(e.target.value)} />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="closure-end">Until</Label>
            <Input id="closure-end" type="datetime-local" value={endVal} onChange={(e) => setEndVal(e.target.value)} />
          </div>
        </div>
        <p className="mt-2 text-[11px] text-ink-mute">
          Times are in your venue timezone ({timezone}). Paid bookings in the window are cancelled
          with a full refund.
        </p>
        {error && <p className="mt-2 text-xs text-danger">{error}</p>}
        <div className="mt-4 flex justify-end">
          <Button onClick={addClosure} disabled={busy}>
            {busy ? 'Saving…' : 'Add closure'}
          </Button>
        </div>
      </div>
    </div>
  );
}

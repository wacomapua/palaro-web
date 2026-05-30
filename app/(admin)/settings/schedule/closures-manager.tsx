'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { Trash2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { createClient } from '@/lib/supabase/client';
import { zonedTimeToUtc } from '@/lib/tz';
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

// Parse a datetime-local value ("YYYY-MM-DDTHH:MM"), interpreted as venue-local
// wall time, into a UTC instant.
function localInputToUtc(value: string, tz: string): Date | null {
  if (!value) return null;
  const [d, t] = value.split('T');
  if (!d || !t) return null;
  const [y, mo, day] = d.split('-').map(Number);
  const [h, mi] = t.split(':').map(Number);
  return zonedTimeToUtc(y, mo, day, h, mi, tz);
}

function fmtRange(startsIso: string, endsIso: string, tz: string): string {
  const dateF = new Intl.DateTimeFormat('en-US', {
    timeZone: tz,
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  });
  return `${dateF.format(new Date(startsIso))} → ${dateF.format(new Date(endsIso))}`;
}

export function ClosuresManager({
  venueId,
  timezone,
  courts,
  closures,
}: {
  venueId: string;
  timezone: string;
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

  const courtName = (id: string | null) =>
    id === null ? 'Whole venue' : courts.find((c) => c.id === id)?.name ?? 'Court';

  async function addClosure() {
    setError(null);
    const startUtc = localInputToUtc(startVal, timezone);
    const endUtc = localInputToUtc(endVal, timezone);
    if (!startUtc || !endUtc) {
      setError('Pick a start and end.');
      return;
    }
    if (endUtc <= startUtc) {
      setError('End must be after start.');
      return;
    }
    setBusy(true);
    const supabase = createClient();

    const { error: insErr } = await supabase.from('venue_closures').insert({
      venue_id: venueId,
      court_id: courtId || null,
      starts_at: startUtc.toISOString(),
      ends_at: endUtc.toISOString(),
      reason: reason || null,
    });
    if (insErr) {
      setError(insErr.message);
      setBusy(false);
      return;
    }

    // Close any currently-OPEN slots that fall inside the window. Booked/held
    // slots are left for the owner to handle (cancel/refund).
    let upd = supabase
      .from('venue_slots')
      .update({ status: 'closed' })
      .eq('venue_id', venueId)
      .eq('status', 'available')
      .lt('starts_at', endUtc.toISOString())
      .gt('ends_at', startUtc.toISOString());
    if (courtId) upd = upd.eq('court_id', courtId);
    await upd;

    setBusy(false);
    setStartVal('');
    setEndVal('');
    setReason('');
    router.refresh();
  }

  async function remove(id: string) {
    if (!confirm('Remove this closure? (Slots already closed stay closed.)')) return;
    setBusy(true);
    const supabase = createClient();
    await supabase.from('venue_closures').delete().eq('id', id);
    setBusy(false);
    router.refresh();
  }

  return (
    <div className="space-y-5">
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
        <p className="mt-2 text-[11px] text-ink-mute">Times are in your venue timezone ({timezone}).</p>
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

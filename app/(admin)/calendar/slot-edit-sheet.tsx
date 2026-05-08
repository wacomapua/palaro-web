'use client';

import { useState } from 'react';
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetDescription } from '@/components/ui/sheet';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { createClient } from '@/lib/supabase/client';
import { formatMoney, formatDateTime } from '@/lib/format';
import type { VenueCourt, VenueSlot } from '@/lib/types/db';

type Editing =
  | { kind: 'new'; courtId: string; hour: number }
  | { kind: 'edit'; slotId: string };

export function SlotEditSheet({
  venueId,
  editing,
  date,
  courts,
  existingSlot,
  existingBooking,
  currency,
  onClose,
  onSaved,
}: {
  venueId: string;
  editing: Editing;
  date: Date;
  courts: VenueCourt[];
  existingSlot: VenueSlot | null;
  existingBooking: { id: string; status: string; captain: { display_name: string | null } | null } | null;
  currency: string;
  onClose: () => void;
  onSaved: () => void;
}) {
  const isNew = editing.kind === 'new';
  const court = isNew
    ? courts.find((c) => c.id === editing.courtId)
    : existingSlot
      ? courts.find((c) => c.id === existingSlot.court_id)
      : null;

  // Default to 2-hour blocks; venue can override.
  const initialStart = isNew
    ? new Date(date.getFullYear(), date.getMonth(), date.getDate(), editing.hour, 0)
    : new Date(existingSlot!.starts_at);
  const initialEnd = isNew
    ? new Date(initialStart.getTime() + 2 * 3_600_000)
    : new Date(existingSlot!.ends_at);

  const [startTime, setStartTime] = useState(toLocalTime(initialStart));
  const [endTime, setEndTime] = useState(toLocalTime(initialEnd));
  // Track the price as the literal string the user is typing, so backspace
  // and edits behave the way a text field should. We derive cents from it
  // when saving — this avoids the type=number controlled-input weirdness
  // (leading zeros, hard-to-clear digits).
  const [priceText, setPriceText] = useState<string>(
    String(Math.round((existingSlot?.price_cents ?? 200_000) / 100)),
  );
  const priceCents = Math.max(0, Math.round((Number(priceText) || 0) * 100));
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    setSubmitting(true);
    setError(null);

    const supabase = createClient();
    const dayMid = new Date(date.getFullYear(), date.getMonth(), date.getDate());
    const starts = mergeDateTime(dayMid, startTime);
    const ends = mergeDateTime(dayMid, endTime);

    if (ends <= starts) {
      setError('End time must be after start time');
      setSubmitting(false);
      return;
    }

    if (isNew && court) {
      const { error: insErr } = await supabase.from('venue_slots').insert({
        venue_id: venueId,
        court_id: court.id,
        starts_at: starts.toISOString(),
        ends_at: ends.toISOString(),
        price_cents: priceCents,
        currency,
        status: 'available',
      });
      if (insErr) {
        setError(insErr.message);
        setSubmitting(false);
        return;
      }
    } else if (existingSlot) {
      const { error: updErr } = await supabase
        .from('venue_slots')
        .update({
          starts_at: starts.toISOString(),
          ends_at: ends.toISOString(),
          price_cents: priceCents,
        })
        .eq('id', existingSlot.id);
      if (updErr) {
        setError(updErr.message);
        setSubmitting(false);
        return;
      }
    }

    setSubmitting(false);
    onSaved();
  }

  async function close() {
    if (!existingSlot) return;
    setSubmitting(true);
    const supabase = createClient();
    const { error: updErr } = await supabase
      .from('venue_slots')
      .update({ status: 'closed' })
      .eq('id', existingSlot.id);
    setSubmitting(false);
    if (updErr) {
      setError(updErr.message);
      return;
    }
    onSaved();
  }

  return (
    <Sheet open onOpenChange={(o) => !o && onClose()}>
      <SheetContent>
        <SheetHeader>
          <SheetTitle>{isNew ? 'New slot' : 'Edit slot'}</SheetTitle>
          <SheetDescription>
            {court?.name ?? 'Court'} · {formatDateTime(date)}
          </SheetDescription>
        </SheetHeader>

        <div className="space-y-5 px-6 pb-6">
          {existingBooking && (
            <div className="rounded-md border border-line/60 bg-bg-2/60 p-3">
              <div className="flex items-center justify-between">
                <p className="text-xs text-ink-dim">Booked by</p>
                <Badge tone={existingBooking.status === 'paid' ? 'brand' : 'warn'} className="capitalize">
                  {existingBooking.status.replace('_', ' ')}
                </Badge>
              </div>
              <p className="mt-1 text-sm font-medium">
                {existingBooking.captain?.display_name ?? 'Captain'}
              </p>
            </div>
          )}

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1.5">
              <Label htmlFor="start">Start</Label>
              <Input
                id="start"
                type="time"
                step={300}
                value={startTime}
                onChange={(e) => setStartTime(e.target.value)}
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="end">End</Label>
              <Input
                id="end"
                type="time"
                step={300}
                value={endTime}
                onChange={(e) => setEndTime(e.target.value)}
              />
            </div>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="price">Price</Label>
            <div className="flex items-center gap-2">
              <span className="text-ink-dim font-mono">₱</span>
              <Input
                id="price"
                type="text"
                inputMode="numeric"
                pattern="[0-9]*"
                value={priceText}
                onChange={(e) => {
                  // Strip non-digits and leading zeros (but allow "" while typing).
                  const digits = e.target.value.replace(/[^0-9]/g, '');
                  const cleaned = digits.replace(/^0+(?=\d)/, '');
                  setPriceText(cleaned);
                }}
                onBlur={() => {
                  if (priceText === '') setPriceText('0');
                }}
                placeholder="2000"
              />
            </div>
            <p className="text-xs text-ink-mute">
              Captain pays {formatMoney(priceCents, currency)}; you net{' '}
              {formatMoney(Math.round(priceCents * 0.95), currency)} after the 5% platform fee.
            </p>
          </div>

          {error && <p className="text-xs text-danger">{error}</p>}

          <div className="flex justify-between gap-2 pt-2">
            {!isNew && existingSlot?.status === 'available' && (
              <Button variant="ghost" onClick={close} disabled={submitting}>
                Close slot
              </Button>
            )}
            <div className="ml-auto flex gap-2">
              <Button variant="ghost" onClick={onClose} disabled={submitting}>
                Cancel
              </Button>
              <Button
                onClick={save}
                disabled={submitting || (!isNew && existingSlot?.status === 'booked')}
              >
                {submitting ? 'Saving…' : 'Save slot'}
              </Button>
            </div>
          </div>
        </div>
      </SheetContent>
    </Sheet>
  );
}

function toLocalTime(d: Date): string {
  return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`;
}

function mergeDateTime(day: Date, hhmm: string): Date {
  const [h, m] = hhmm.split(':').map(Number);
  const out = new Date(day);
  out.setHours(h, m, 0, 0);
  return out;
}

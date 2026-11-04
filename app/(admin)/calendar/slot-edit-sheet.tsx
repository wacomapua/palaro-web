'use client';

import { useState } from 'react';
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetDescription } from '@/components/ui/sheet';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { createClient } from '@/lib/supabase/client';
import { formatMoney } from '@/lib/format';
import { zonedTimeToUtc, tzParts, formatTimeInTz, formatYmd } from '@/lib/tz';
import type { CourtSlotModel } from '@/lib/sport-presets';
import type { VenueCourt, VenueSlot } from '@/lib/types/db';

// "HH:MM" wall-clock time on a venue-local day → UTC instant.
function localTimeToUtc(dayYmd: string, hhmm: string, tz: string): Date {
  const [y, mo, d] = dayYmd.split('-').map(Number);
  const [h, m] = hhmm.split(':').map(Number);
  return zonedTimeToUtc(y, mo, d, h, m, tz);
}

function hhmm(totalMinutes: number): string {
  const t = Math.max(0, Math.min(totalMinutes, 23 * 60 + 59));
  return `${String(Math.floor(t / 60)).padStart(2, '0')}:${String(t % 60).padStart(2, '0')}`;
}

// HH:MM of a slot timestamp as seen in the venue timezone.
function slotHHMM(iso: string, tz: string): string {
  const p = tzParts(new Date(iso), tz);
  return `${String(p.hour).padStart(2, '0')}:${String(p.minute).padStart(2, '0')}`;
}

type Editing =
  | { kind: 'new'; courtId: string; hour: number }
  | { kind: 'edit'; slotId: string };

interface SlotBooking {
  id: string;
  status: string;
  party_size: number;
  captain: { display_name: string | null } | null;
}

// The court's slot-generation model lives on venue_courts.metadata.slotModel
// (written by the onboarding builder). Fall back sensibly for older courts.
function readSlotModel(court: VenueCourt | null | undefined): CourtSlotModel {
  const raw = (court?.metadata as { slotModel?: Partial<CourtSlotModel> } | null)?.slotModel;
  if (raw && raw.bookingMode) {
    return {
      bookingMode: raw.bookingMode,
      pricingMode: raw.pricingMode ?? 'per_slot',
      defaultDurationMinutes: raw.defaultDurationMinutes ?? 120,
      teeIntervalMinutes: raw.teeIntervalMinutes,
      maxPlayers: raw.maxPlayers,
    };
  }
  // Legacy / hand-added golf course with no metadata → assume a tee sheet.
  if (court?.sport === 'golf' && court?.kind === 'course') {
    return {
      bookingMode: 'shared',
      pricingMode: 'per_player',
      defaultDurationMinutes: 10,
      teeIntervalMinutes: 10,
      maxPlayers: 4,
    };
  }
  return { bookingMode: 'exclusive', pricingMode: 'per_slot', defaultDurationMinutes: 120 };
}

export function SlotEditSheet({
  venueId,
  editing,
  dayYmd,
  timezone,
  courts,
  existingSlot,
  existingBookings,
  currency,
  onClose,
  onSaved,
}: {
  venueId: string;
  editing: Editing;
  dayYmd: string;
  timezone: string;
  courts: VenueCourt[];
  existingSlot: VenueSlot | null;
  existingBookings: SlotBooking[];
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

  const model = readSlotModel(court);
  const isTee = model.bookingMode === 'shared' && !!model.teeIntervalMinutes;

  if (isTee && isNew && court) {
    return (
      <TeeSheetGenerator
        venueId={venueId}
        court={court}
        model={model}
        dayYmd={dayYmd}
        timezone={timezone}
        editing={editing as { kind: 'new'; courtId: string; hour: number }}
        currency={currency}
        onClose={onClose}
        onSaved={onSaved}
      />
    );
  }

  return (
    <SingleSlotEditor
      venueId={venueId}
      court={court ?? null}
      model={model}
      dayYmd={dayYmd}
      timezone={timezone}
      editing={editing}
      existingSlot={existingSlot}
      existingBookings={existingBookings}
      currency={currency}
      onClose={onClose}
      onSaved={onSaved}
    />
  );
}

// ---------------------------------------------------------------------------
// Tee-sheet generator: bulk-create back-to-back tee times for a golf course.
// ---------------------------------------------------------------------------
function TeeSheetGenerator({
  venueId,
  court,
  model,
  dayYmd,
  timezone,
  editing,
  currency,
  onClose,
  onSaved,
}: {
  venueId: string;
  court: VenueCourt;
  model: CourtSlotModel;
  dayYmd: string;
  timezone: string;
  editing: { kind: 'new'; courtId: string; hour: number };
  currency: string;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [startTime, setStartTime] = useState(`${String(editing.hour).padStart(2, '0')}:00`);
  const [endTime, setEndTime] = useState(`${String(Math.min(editing.hour + 4, 23)).padStart(2, '0')}:00`);
  const [interval, setInterval] = useState<number>(model.teeIntervalMinutes ?? 10);
  const [maxPlayers, setMaxPlayers] = useState<number>(model.maxPlayers ?? 4);
  const [priceText, setPriceText] = useState<string>('1500'); // per player
  const pricePerPlayer = Math.max(0, Math.round((Number(priceText) || 0) * 100));
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const starts = localTimeToUtc(dayYmd, startTime, timezone);
  const ends = localTimeToUtc(dayYmd, endTime, timezone);
  const teeTimes = enumerateTeeTimes(starts, ends, interval);

  async function generate() {
    if (teeTimes.length === 0) {
      setError('End time must be after start, with at least one interval between.');
      return;
    }
    setSubmitting(true);
    setError(null);

    const rows = teeTimes.map((t) => ({
      venue_id: venueId,
      court_id: court.id,
      starts_at: t.toISOString(),
      ends_at: new Date(t.getTime() + interval * 60_000).toISOString(),
      price_cents: pricePerPlayer, // legacy column mirrors per-player price
      price_per_player_cents: pricePerPlayer,
      currency,
      status: 'available' as const,
      booking_mode: 'shared' as const,
      pricing_mode: 'per_player' as const,
      max_players: maxPlayers,
    }));

    const supabase = createClient();
    const { error: insErr } = await supabase.from('venue_slots').insert(rows);
    if (insErr) {
      setError(insErr.message);
      setSubmitting(false);
      return;
    }
    setSubmitting(false);
    onSaved();
  }

  return (
    <Sheet open onOpenChange={(o) => !o && onClose()}>
      <SheetContent>
        <SheetHeader>
          <SheetTitle>Generate tee sheet</SheetTitle>
          <SheetDescription>
            {court.name} · {formatYmd(dayYmd)}
          </SheetDescription>
        </SheetHeader>

        <div className="space-y-5 px-6 pb-6">
          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1.5">
              <Label htmlFor="start">First tee-off</Label>
              <Input id="start" type="time" step={300} value={startTime} onChange={(e) => setStartTime(e.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="end">Last tee-off before</Label>
              <Input id="end" type="time" step={300} value={endTime} onChange={(e) => setEndTime(e.target.value)} />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1.5">
              <Label htmlFor="interval">Interval (min)</Label>
              <Input
                id="interval"
                type="number"
                min={5}
                max={20}
                value={interval}
                onChange={(e) => setInterval(Math.max(5, Number(e.target.value) || 10))}
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="max">Players per tee time</Label>
              <Input
                id="max"
                type="number"
                min={1}
                max={6}
                value={maxPlayers}
                onChange={(e) => setMaxPlayers(Math.max(1, Number(e.target.value) || 4))}
              />
            </div>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="price">Price per golfer</Label>
            <div className="flex items-center gap-2">
              <span className="text-ink-dim font-mono">₱</span>
              <Input
                id="price"
                type="text"
                inputMode="numeric"
                value={priceText}
                onChange={(e) => setPriceText(e.target.value.replace(/[^0-9]/g, '').replace(/^0+(?=\d)/, ''))}
                onBlur={() => priceText === '' && setPriceText('0')}
                placeholder="1500"
              />
            </div>
            <p className="text-xs text-ink-mute">
              A full {maxPlayers}-ball brings {formatMoney(pricePerPlayer * maxPlayers, currency)};
              you net {formatMoney(Math.round(pricePerPlayer * maxPlayers * 0.95), currency)} after
              the 5% platform fee.
            </p>
          </div>

          <div className="rounded-md border border-line/60 bg-bg-2/50 p-3 text-sm">
            <span className="font-mono text-ink">{teeTimes.length}</span> tee times will be created
            {teeTimes.length > 0 && (
              <span className="text-ink-dim">
                {' '}
                ({formatTimeInTz(teeTimes[0], timezone)} →{' '}
                {formatTimeInTz(teeTimes[teeTimes.length - 1], timezone)})
              </span>
            )}
            .
          </div>

          {error && <p className="text-xs text-danger">{error}</p>}

          <div className="flex justify-end gap-2 pt-2">
            <Button variant="ghost" onClick={onClose} disabled={submitting}>
              Cancel
            </Button>
            <Button onClick={generate} disabled={submitting || teeTimes.length === 0}>
              {submitting ? 'Generating…' : `Generate ${teeTimes.length} tee times`}
            </Button>
          </div>
        </div>
      </SheetContent>
    </Sheet>
  );
}

// ---------------------------------------------------------------------------
// Single-slot editor: court-sport blocks AND editing one golf tee time.
// ---------------------------------------------------------------------------
function SingleSlotEditor({
  venueId,
  court,
  model,
  dayYmd,
  timezone,
  editing,
  existingSlot,
  existingBookings,
  currency,
  onClose,
  onSaved,
}: {
  venueId: string;
  court: VenueCourt | null;
  model: CourtSlotModel;
  dayYmd: string;
  timezone: string;
  editing: Editing;
  existingSlot: VenueSlot | null;
  existingBookings: SlotBooking[];
  currency: string;
  onClose: () => void;
  onSaved: () => void;
}) {
  const isNew = editing.kind === 'new';
  const perPlayer = existingSlot ? existingSlot.pricing_mode === 'per_player' : model.pricingMode === 'per_player';
  const shared = existingSlot ? existingSlot.booking_mode === 'shared' : model.bookingMode === 'shared';

  const durationMin = model.defaultDurationMinutes || 120;
  // New slots seed from the clicked hour; existing slots from their own times
  // (rendered in the venue timezone).
  const clickedHour = editing.kind === 'new' ? editing.hour : 0;
  const [startTime, setStartTime] = useState(
    existingSlot ? slotHHMM(existingSlot.starts_at, timezone) : hhmm(clickedHour * 60),
  );
  const [endTime, setEndTime] = useState(
    existingSlot
      ? slotHHMM(existingSlot.ends_at, timezone)
      : hhmm(clickedHour * 60 + durationMin),
  );

  const seedPrice = perPlayer
    ? existingSlot?.price_per_player_cents ?? existingSlot?.price_cents ?? 150_000
    : existingSlot?.price_cents ?? 200_000;
  const [priceText, setPriceText] = useState<string>(String(Math.round(seedPrice / 100)));
  const priceCents = Math.max(0, Math.round((Number(priceText) || 0) * 100));
  const [maxPlayers, setMaxPlayers] = useState<number>(existingSlot?.max_players ?? model.maxPlayers ?? 4);

  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const bookedPlayers = existingBookings
    .filter((b) => ['paid', 'pending_payment', 'completed'].includes(b.status))
    .reduce((s, b) => s + (b.party_size ?? 1), 0);
  const hasBookings = bookedPlayers > 0;

  async function save() {
    setSubmitting(true);
    setError(null);

    const supabase = createClient();
    const starts = localTimeToUtc(dayYmd, startTime, timezone);
    const ends = localTimeToUtc(dayYmd, endTime, timezone);

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
        price_per_player_cents: perPlayer ? priceCents : null,
        currency,
        status: 'available',
        booking_mode: shared ? 'shared' : 'exclusive',
        pricing_mode: perPlayer ? 'per_player' : 'per_slot',
        max_players: shared ? maxPlayers : null,
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
          price_per_player_cents: perPlayer ? priceCents : null,
          max_players: shared ? maxPlayers : null,
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

  async function closeSlot() {
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
          <SheetTitle>{isNew ? 'New slot' : shared ? 'Tee time' : 'Edit slot'}</SheetTitle>
          <SheetDescription>
            {court?.name ?? 'Court'} · {formatYmd(dayYmd)}
          </SheetDescription>
        </SheetHeader>

        <div className="space-y-5 px-6 pb-6">
          {shared && !isNew && (
            <div className="rounded-md border border-line/60 bg-bg-2/60 p-3">
              <div className="flex items-center justify-between">
                <p className="text-xs text-ink-dim">Tee time fill</p>
                <Badge tone={bookedPlayers >= maxPlayers ? 'brand' : bookedPlayers > 0 ? 'warn' : 'neutral'}>
                  {bookedPlayers}/{maxPlayers} players
                </Badge>
              </div>
              {existingBookings.length > 0 && (
                <ul className="mt-2 space-y-1 text-sm">
                  {existingBookings.map((b) => (
                    <li key={b.id} className="flex items-center justify-between">
                      <span>{b.captain?.display_name ?? 'Player'}</span>
                      <span className="text-ink-dim">×{b.party_size ?? 1}</span>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          )}

          {!shared && existingBookings[0] && (
            <div className="rounded-md border border-line/60 bg-bg-2/60 p-3">
              <div className="flex items-center justify-between">
                <p className="text-xs text-ink-dim">Booked by</p>
                <Badge tone={existingBookings[0].status === 'paid' ? 'brand' : 'warn'} className="capitalize">
                  {existingBookings[0].status.replace('_', ' ')}
                </Badge>
              </div>
              <p className="mt-1 text-sm font-medium">
                {existingBookings[0].captain?.display_name ?? 'Captain'}
              </p>
            </div>
          )}

          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-1.5">
              <Label htmlFor="start">Start</Label>
              <Input id="start" type="time" step={300} value={startTime} onChange={(e) => setStartTime(e.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="end">End</Label>
              <Input id="end" type="time" step={300} value={endTime} onChange={(e) => setEndTime(e.target.value)} />
            </div>
          </div>

          {shared && (
            <div className="space-y-1.5">
              <Label htmlFor="max">Max players</Label>
              <Input
                id="max"
                type="number"
                min={Math.max(1, bookedPlayers)}
                max={6}
                value={maxPlayers}
                onChange={(e) => setMaxPlayers(Math.max(1, Number(e.target.value) || 4))}
                className="w-32"
              />
            </div>
          )}

          <div className="space-y-1.5">
            <Label htmlFor="price">{perPlayer ? 'Price per golfer' : 'Price'}</Label>
            <div className="flex items-center gap-2">
              <span className="text-ink-dim font-mono">₱</span>
              <Input
                id="price"
                type="text"
                inputMode="numeric"
                pattern="[0-9]*"
                value={priceText}
                onChange={(e) => setPriceText(e.target.value.replace(/[^0-9]/g, '').replace(/^0+(?=\d)/, ''))}
                onBlur={() => priceText === '' && setPriceText('0')}
                placeholder={perPlayer ? '1500' : '2000'}
              />
            </div>
            <p className="text-xs text-ink-mute">
              {perPlayer ? (
                <>
                  Each golfer pays {formatMoney(priceCents, currency)}; a full {maxPlayers}-ball nets
                  you {formatMoney(Math.round(priceCents * maxPlayers * 0.95), currency)} after the 5%
                  fee.
                </>
              ) : (
                <>
                  Captain pays {formatMoney(priceCents, currency)}; you net{' '}
                  {formatMoney(Math.round(priceCents * 0.95), currency)} after the 5% platform fee.
                </>
              )}
            </p>
          </div>

          {error && <p className="text-xs text-danger">{error}</p>}

          <div className="flex justify-between gap-2 pt-2">
            {!isNew && existingSlot?.status === 'available' && !hasBookings && (
              <Button variant="ghost" onClick={closeSlot} disabled={submitting}>
                Close slot
              </Button>
            )}
            <div className="ml-auto flex gap-2">
              <Button variant="ghost" onClick={onClose} disabled={submitting}>
                Cancel
              </Button>
              <Button
                onClick={save}
                disabled={submitting || (!isNew && !shared && existingSlot?.status === 'booked')}
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

function enumerateTeeTimes(start: Date, end: Date, intervalMin: number): Date[] {
  const out: Date[] = [];
  if (!(end > start) || intervalMin < 1) return out;
  let t = new Date(start);
  // Cap to avoid runaway inserts.
  while (t < end && out.length < 200) {
    out.push(new Date(t));
    t = new Date(t.getTime() + intervalMin * 60_000);
  }
  return out;
}


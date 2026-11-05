// Tee sheet rows for the admin calendar, kept free of React so `node --test`
// can import it directly.
//
// Golf (contract C14): a course has one tee sheet. Each tee time has up to 4
// spots; a booking is a single, twosome, threesome or foursome who chose 9 or
// 18 holes. The calendar lists a course's tee times for the day as rows
// instead of drawing them on the hourly court timeline. Times are shown in the
// venue timezone (lib/tz.ts), never the device's.

import { courtSlotModel } from './sport-presets.ts';
import { formatTimeInTz, tzParts } from './tz.ts';
import type { GolfHoles, Json, VenueSlotStatus, VenueSport } from '@/lib/types/db';

// Spots on a tee time when the slot does not say (a foursome).
export const TEE_TIME_SPOTS = 4;

// Bookings that hold spots, as book_venue_slot counts them.
const ACTIVE_BOOKING = new Set(['pending_payment', 'paid', 'completed']);

export interface TeeSheetCourt {
  id: string;
  name: string;
  sport: VenueSport;
  kind: string | null;
  metadata: Json | null;
}

export interface TeeSheetSlot {
  id: string;
  court_id: string;
  starts_at: string;
  status: VenueSlotStatus;
  max_players: number | null;
  price_cents: number;
  price_per_player_cents: number | null;
  price_per_player_9_cents?: number | null;
}

export interface TeeSheetBooking {
  id: string;
  slot_id: string;
  status: string;
  party_size: number;
  holes?: number | null;
  captain: { display_name: string | null } | null;
}

export type TeeTimeStatus = 'open' | 'partly_booked' | 'full' | 'closed';
export type SpotState = 'paid' | 'pending' | 'open';

export interface TeeSheetParty {
  id: string;
  name: string;
  partySize: number;
  partyLabel: string;
  holes: GolfHoles;
  holesLabel: string;
  // Booked but not paid yet (pending_payment).
  pending: boolean;
}

export interface TeeSheetRow {
  slotId: string;
  startsAt: string;
  time: string; // venue local, e.g. "7:10 AM"
  hour: number; // venue local hour 0-23
  newHour: boolean; // first row of its hour
  capacity: number;
  booked: number;
  spots: SpotState[];
  parties: TeeSheetParty[];
  status: TeeTimeStatus;
  statusLabel: string;
  price18Cents: number;
  price9Cents: number | null; // null: 9 hole rounds not offered
}

export interface TeeSheetSummary {
  teeTimes: number;
  bookable: number; // open or partly booked
  golfers: number;
  spots: number; // on tee times that are not closed
}

export interface TeeSheet {
  court: TeeSheetCourt;
  rows: TeeSheetRow[];
  summary: TeeSheetSummary;
}

const STATUS_LABEL: Record<TeeTimeStatus, string> = {
  open: 'Open',
  partly_booked: 'Partly booked',
  full: 'Full',
  closed: 'Closed',
};

const PARTY_LABEL = ['Single', 'Twosome', 'Threesome', 'Foursome'];

export function partyLabel(size: number): string {
  return PARTY_LABEL[size - 1] ?? `${size} golfers`;
}

export function holesLabel(holes: number): string {
  return `${holes} holes`;
}

function toHoles(h: number | null | undefined): GolfHoles {
  return h === 9 ? 9 : 18;
}

// A golf course booked as a shared tee sheet. Courts made from the old driving
// range preset are exclusive and stay on the hourly timeline.
export function isTeeSheetCourt(court: Pick<TeeSheetCourt, 'sport' | 'kind' | 'metadata'>): boolean {
  return court.sport === 'golf' && courtSlotModel(court).bookingMode === 'shared';
}

function teeTimeStatus(slot: TeeSheetSlot, booked: number, capacity: number): TeeTimeStatus {
  if (slot.status === 'closed' || slot.status === 'cancelled') return 'closed';
  if (slot.status === 'booked' || booked >= capacity) return 'full';
  return booked > 0 ? 'partly_booked' : 'open';
}

function buildRow(slot: TeeSheetSlot, bookings: TeeSheetBooking[], tz: string, prevHour: number | null): TeeSheetRow {
  const start = new Date(slot.starts_at);
  const hour = tzParts(start, tz).hour;
  const capacity = slot.max_players ?? TEE_TIME_SPOTS;

  const parties: TeeSheetParty[] = bookings.map((b) => {
    const holes = toHoles(b.holes);
    const size = b.party_size ?? 1;
    return {
      id: b.id,
      name: b.captain?.display_name || 'Golfer',
      partySize: size,
      partyLabel: partyLabel(size),
      holes,
      holesLabel: holesLabel(holes),
      pending: b.status === 'pending_payment',
    };
  });
  const paid = parties.filter((p) => !p.pending).reduce((n, p) => n + p.partySize, 0);
  const pending = parties.filter((p) => p.pending).reduce((n, p) => n + p.partySize, 0);
  const booked = paid + pending;

  const spots: SpotState[] = [];
  for (let i = 0; i < capacity; i++) {
    spots.push(i < paid ? 'paid' : i < booked ? 'pending' : 'open');
  }

  const status = teeTimeStatus(slot, booked, capacity);
  return {
    slotId: slot.id,
    startsAt: slot.starts_at,
    time: formatTimeInTz(start, tz),
    hour,
    newHour: prevHour === null || prevHour !== hour,
    capacity,
    booked,
    spots,
    parties,
    status,
    statusLabel: STATUS_LABEL[status],
    // Same fallback as book_venue_slot for the 18 hole price; no fallback for 9.
    price18Cents: slot.price_per_player_cents ?? slot.price_cents,
    price9Cents: slot.price_per_player_9_cents ?? null,
  };
}

// One sheet per tee sheet court (in the order given), each with that court's
// tee times sorted by start. Courts that are not tee sheets are left out.
export function buildTeeSheets({
  courts,
  slots,
  bookings,
  tz,
}: {
  courts: TeeSheetCourt[];
  slots: TeeSheetSlot[];
  bookings: TeeSheetBooking[];
  tz: string;
}): TeeSheet[] {
  const bySlot = new Map<string, TeeSheetBooking[]>();
  for (const b of bookings) {
    if (!ACTIVE_BOOKING.has(b.status)) continue;
    const arr = bySlot.get(b.slot_id) ?? [];
    arr.push(b);
    bySlot.set(b.slot_id, arr);
  }

  return courts.filter(isTeeSheetCourt).map((court) => {
    const courtSlots = slots
      .filter((s) => s.court_id === court.id)
      .sort((a, b) => new Date(a.starts_at).getTime() - new Date(b.starts_at).getTime());

    const rows: TeeSheetRow[] = [];
    for (const s of courtSlots) {
      const prev = rows.at(-1);
      rows.push(buildRow(s, bySlot.get(s.id) ?? [], tz, prev ? prev.hour : null));
    }

    const live = rows.filter((r) => r.status !== 'closed');
    return {
      court,
      rows,
      summary: {
        teeTimes: rows.length,
        bookable: rows.filter((r) => r.status === 'open' || r.status === 'partly_booked').length,
        golfers: rows.reduce((n, r) => n + r.booked, 0),
        spots: live.reduce((n, r) => n + r.capacity, 0),
      },
    };
  });
}

// ---------------------------------------------------------------------------
// Tee time editor and generator (C14)
// ---------------------------------------------------------------------------

// A tee time is a single, twosome, threesome or foursome at most.
export const MAX_PLAYERS_PER_TEE_TIME = 4;

// "Players per tee time" input: 1 to 4, never below the golfers already
// booked on it (a tee time made before the limit may hold more than 4). An
// empty field means a foursome.
export function clampPlayersPerTeeTime(n: number, booked = 0): number {
  const want = Number.isFinite(n) ? Math.floor(n) : MAX_PLAYERS_PER_TEE_TIME;
  const floor = Math.max(1, booked);
  return Math.max(floor, Math.min(want, Math.max(MAX_PLAYERS_PER_TEE_TIME, booked)));
}

// Price inputs hold whole currency units as digits.
export function priceTextToCents(text: string): number {
  return Math.max(0, Math.round((Number(text) || 0) * 100));
}

// The optional 9 hole price: blank means 9 hole rounds are not offered.
export function optionalPriceTextToCents(text: string): number | null {
  return text.trim() === '' ? null : priceTextToCents(text);
}

export function centsToPriceText(cents: number | null | undefined): string {
  return cents == null ? '' : String(Math.round(cents / 100));
}

// Columns a tee time saves: the 18 hole price per golfer (price_cents mirrors
// it, as before) and the 9 hole price per golfer, null when not offered.
export function teeTimePriceColumns(
  price18Cents: number,
  price9Cents: number | null,
): { price_cents: number; price_per_player_cents: number; price_per_player_9_cents: number | null } {
  return {
    price_cents: price18Cents,
    price_per_player_cents: price18Cents,
    price_per_player_9_cents: price9Cents,
  };
}

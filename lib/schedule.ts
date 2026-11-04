// Weekly schedule logic for /settings/schedule, kept free of React so
// `node --test` can import it directly.
//
// Schedules are set per court group: the venue's active courts of one sport
// with one booking mode. A golf course (shared tee sheet, per golfer price)
// and its range bays (exclusive, hourly) are separate groups. Saving goes
// through the replace_venue_slot_templates RPC, which applies the same group
// rule and validation server side.

import type { BookingMode, Json, VenueSport } from '@/lib/types/db';

export interface ScheduleCourt {
  id: string;
  sport: VenueSport;
  name: string;
  active: boolean;
  metadata?: Json | null;
}

export interface ScheduleTemplate {
  court_id: string;
  day_of_week: number;
  start_time: string;
  end_time: string;
  slot_minutes: number;
  price_cents: number;
  active: boolean;
}

export interface DaySchedule {
  enabled: boolean;
  open: string; // HH:MM
  close: string;
  slotMinutes: number;
  price: string; // major units, digits only
}

export type Week = Record<number, DaySchedule>;

export interface CourtGroup {
  key: string; // `${sport}:${bookingMode}`
  sport: VenueSport;
  bookingMode: BookingMode;
  courts: ScheduleCourt[];
}

// One entry of the replace_venue_slot_templates payload.
export interface TemplateInput {
  day_of_week: number;
  start_time: string;
  end_time: string;
  slot_minutes: number;
  price_cents: number;
}

// Display order Mon to Sun, stored as JS day_of_week (0 = Sunday).
export const DAYS: { dow: number; label: string }[] = [
  { dow: 1, label: 'Mon' },
  { dow: 2, label: 'Tue' },
  { dow: 3, label: 'Wed' },
  { dow: 4, label: 'Thu' },
  { dow: 5, label: 'Fri' },
  { dow: 6, label: 'Sat' },
  { dow: 0, label: 'Sun' },
];

// Server limits enforced by generate_venue_slots.
export const GENERATE_MAX_DAYS = 90;
export const GENERATE_MAX_ROWS = 20000;

interface SlotModelMeta {
  bookingMode?: unknown;
  teeIntervalMinutes?: unknown;
  defaultDurationMinutes?: unknown;
}

function slotModel(court: ScheduleCourt): SlotModelMeta | null {
  const meta = court.metadata;
  if (!meta || typeof meta !== 'object' || Array.isArray(meta)) return null;
  const model = (meta as Record<string, Json>).slotModel;
  if (!model || typeof model !== 'object' || Array.isArray(model)) return null;
  return model as SlotModelMeta;
}

// Mirrors generate_venue_slots: metadata.slotModel.bookingMode, else exclusive.
export function courtBookingMode(court: ScheduleCourt): BookingMode {
  return slotModel(court)?.bookingMode === 'shared' ? 'shared' : 'exclusive';
}

// Active courts grouped by (sport, booking mode). Sports follow sportOrder
// (the venue's primary sport first); within a sport, groups appear in court
// order.
export function courtGroups(courts: ScheduleCourt[], sportOrder: VenueSport[] = []): CourtGroup[] {
  const groups = new Map<string, CourtGroup>();
  for (const court of courts) {
    if (!court.active) continue;
    const bookingMode = courtBookingMode(court);
    const key = `${court.sport}:${bookingMode}`;
    let group = groups.get(key);
    if (!group) {
      group = { key, sport: court.sport, bookingMode, courts: [] };
      groups.set(key, group);
    }
    group.courts.push(court);
  }
  const rank = (s: VenueSport) => {
    const i = sportOrder.indexOf(s);
    return i === -1 ? sportOrder.length : i;
  };
  // Array.prototype.sort is stable, so court order survives within a rank.
  return [...groups.values()].sort((a, b) => rank(a.sport) - rank(b.sport));
}

export function groupLabel(group: CourtGroup, all: CourtGroup[], sportLabel: (s: VenueSport) => string): string {
  const base = sportLabel(group.sport);
  if (all.filter((g) => g.sport === group.sport).length < 2) return base;
  const golf = group.sport === 'golf';
  const mode = group.bookingMode === 'shared' ? (golf ? 'tee times' : 'shared slots') : golf ? 'bays' : 'courts';
  return `${base} · ${mode}`;
}

export function defaultSlotMinutes(group: CourtGroup): number {
  for (const court of group.courts) {
    const model = slotModel(court);
    const minutes = group.bookingMode === 'shared' ? model?.teeIntervalMinutes : model?.defaultDurationMinutes;
    if (typeof minutes === 'number' && Number.isInteger(minutes) && minutes >= 5) return minutes;
  }
  return group.bookingMode === 'shared' ? 10 : 60;
}

export function emptyWeek(slotMinutes: number): Week {
  const week: Week = {};
  for (const { dow } of DAYS) {
    week[dow] = { enabled: false, open: '09:00', close: '20:00', slotMinutes, price: '1500' };
  }
  return week;
}

// A group's saved week. The RPC writes the same rows for every active court
// in the group, so the first court that has templates speaks for all.
export function seedWeek(group: CourtGroup, templates: ScheduleTemplate[]): Week {
  const week = emptyWeek(defaultSlotMinutes(group));
  const ids = group.courts.map((c) => c.id);
  const source = ids.find((id) => templates.some((t) => t.court_id === id && t.active));
  if (!source) return week;
  for (const t of templates) {
    if (t.court_id !== source || !t.active) continue;
    week[t.day_of_week] = {
      enabled: true,
      open: t.start_time.slice(0, 5),
      close: t.end_time.slice(0, 5),
      slotMinutes: t.slot_minutes,
      price: String(Math.round(t.price_cents / 100)),
    };
  }
  return week;
}

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;
const MAX_PRICE_CENTS = 2_147_483_647; // price_cents is a Postgres int

function minutesOf(hhmm: string): number {
  const [h, m] = hhmm.split(':').map(Number);
  return h * 60 + m;
}

// Validates the whole week first (same rules as the RPC), then builds the
// payload. Nothing is sent unless every enabled day is valid.
export function buildTemplatePayload(
  week: Week,
): { ok: true; templates: TemplateInput[] } | { ok: false; error: string } {
  const templates: TemplateInput[] = [];
  for (const { dow, label } of DAYS) {
    const day = week[dow];
    if (!day?.enabled) continue;
    if (!HHMM.test(day.open) || !HHMM.test(day.close)) {
      return { ok: false, error: `${label}: enter opening and closing times.` };
    }
    const span = minutesOf(day.close) - minutesOf(day.open);
    if (span <= 0) return { ok: false, error: `${label}: closing time must be after opening time.` };
    if (!Number.isInteger(day.slotMinutes) || day.slotMinutes < 5 || day.slotMinutes > 1440) {
      return { ok: false, error: `${label}: slot length must be a whole number from 5 to 1440 minutes.` };
    }
    if (day.slotMinutes > span) return { ok: false, error: `${label}: slot length is longer than the opening hours.` };
    if (!/^\d+$/.test(day.price)) return { ok: false, error: `${label}: enter a price (0 for free).` };
    if (Number(day.price) * 100 > MAX_PRICE_CENTS) return { ok: false, error: `${label}: price is too high.` };
    templates.push({
      day_of_week: dow,
      start_time: day.open,
      end_time: day.close,
      slot_minutes: day.slotMinutes,
      price_cents: Number(day.price) * 100,
    });
  }
  return { ok: true, templates };
}

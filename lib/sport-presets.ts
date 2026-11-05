// Sport presets for the court-tree wizard at /onboarding/courts.
// Each preset describes a tree of courts the venue owner can adopt as a
// starting point. After picking, they can rename / reorder / set capacity
// before commit.

import type { VenueSport, BookingMode, PricingMode, Json } from '@/lib/types/db';

export interface PresetNode {
  // Stable id within the preset so we can reference parent in children.
  key: string;
  name: string;
  // Free-text kind that becomes venue_courts.kind. Drives some UI hints
  // (e.g. half-pitch icon vs quarter icon) but isn't enum-checked.
  kind: 'pitch' | 'half' | 'quarter' | 'court' | 'derived' | 'course' | 'lane';
  capacity?: number;
  parentKey?: string; // null = root
}

export interface CourtPreset {
  id: string;
  label: string;
  description: string;
  defaultDurationMinutes: number;
  nodes: PresetNode[];
  // For "N courts" presets: prompt the user for N before generating nodes.
  variableCount?: { min: number; max: number; default: number; namePattern: string };
  // Booking model — defaults to exclusive / per_slot (i.e. "rent the whole
  // court for one block"). Golf-style presets set bookingMode 'shared' with a
  // tee interval so a single tee time holds several independent parties.
  bookingMode?: BookingMode;
  pricingMode?: PricingMode;
  // Minutes between consecutive slots when bulk-generating. Presence of a
  // teeIntervalMinutes signals a tee-sheet (golf): many short slots back to back.
  teeIntervalMinutes?: number;
  // Max players across all bookings of one shared slot (a golf foursome = 4).
  maxPlayers?: number;
}

// The slot-generation model derived from a preset and stored on
// venue_courts.metadata so the calendar knows how to create slots for a court
// without re-deriving it from the sport every time.
export interface CourtSlotModel {
  bookingMode: BookingMode;
  pricingMode: PricingMode;
  defaultDurationMinutes: number;
  teeIntervalMinutes?: number;
  maxPlayers?: number;
}

export function slotModelForPreset(preset: CourtPreset): CourtSlotModel {
  return {
    bookingMode: preset.bookingMode ?? 'exclusive',
    pricingMode: preset.pricingMode ?? 'per_slot',
    defaultDurationMinutes: preset.defaultDurationMinutes,
    teeIntervalMinutes: preset.teeIntervalMinutes,
    maxPlayers: preset.maxPlayers,
  };
}

// The slot model a court was built with, read from
// venue_courts.metadata.slotModel (written by the court builder). Courts made
// from presets that are no longer offered (driving range bays, Front 9 and
// Back 9) keep the model stored on them. Older courts without one: a golf
// course is a tee sheet, anything else is booked exclusively.
export function courtSlotModel(
  court: { sport: VenueSport; kind: string | null; metadata: Json | null } | null | undefined,
): CourtSlotModel {
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

export interface SportConfig {
  sport: VenueSport;
  emoji: string;
  label: string;
  presets: CourtPreset[];
}

export const SPORT_CONFIGS: SportConfig[] = [
  {
    sport: 'football',
    emoji: '⚽',
    label: 'Football',
    presets: [
      {
        id: 'football-full-half-quarter',
        label: 'Full pitch + halves + quarters',
        description: 'Like Emperador Stadium — full 11v11 pitch divisible into halves and quarters for 7-a-side.',
        defaultDurationMinutes: 120,
        nodes: [
          { key: 'full', name: 'Full Pitch', kind: 'pitch', capacity: 22 },
          { key: 'n-half', name: 'North Half', kind: 'half', capacity: 14, parentKey: 'full' },
          { key: 's-half', name: 'South Half', kind: 'half', capacity: 14, parentKey: 'full' },
          { key: 'q1', name: 'Q1', kind: 'quarter', capacity: 14, parentKey: 'n-half' },
          { key: 'q2', name: 'Q2', kind: 'quarter', capacity: 14, parentKey: 'n-half' },
          { key: 'q3', name: 'Q3', kind: 'quarter', capacity: 14, parentKey: 's-half' },
          { key: 'q4', name: 'Q4', kind: 'quarter', capacity: 14, parentKey: 's-half' },
        ],
      },
      {
        id: 'football-full-half',
        label: 'Full pitch + halves only',
        description: 'Standard 11v11 pitch, splittable into two 7-a-side halves.',
        defaultDurationMinutes: 120,
        nodes: [
          { key: 'full', name: 'Full Pitch', kind: 'pitch', capacity: 22 },
          { key: 'n-half', name: 'North Half', kind: 'half', capacity: 14, parentKey: 'full' },
          { key: 's-half', name: 'South Half', kind: 'half', capacity: 14, parentKey: 'full' },
        ],
      },
      {
        id: 'football-single',
        label: 'Single full pitch',
        description: 'One pitch, no subdivisions.',
        defaultDurationMinutes: 120,
        nodes: [{ key: 'full', name: 'Full Pitch', kind: 'pitch', capacity: 22 }],
      },
    ],
  },
  {
    sport: 'basketball',
    emoji: '🏀',
    label: 'Basketball',
    presets: [
      {
        id: 'basketball-full-half',
        label: 'Full court + halves',
        description: 'Full 5v5 court splittable into two half-court (3v3) games.',
        defaultDurationMinutes: 120,
        nodes: [
          { key: 'full', name: 'Full Court', kind: 'court', capacity: 10 },
          { key: 'half-a', name: 'Half A', kind: 'half', capacity: 6, parentKey: 'full' },
          { key: 'half-b', name: 'Half B', kind: 'half', capacity: 6, parentKey: 'full' },
        ],
      },
      {
        id: 'basketball-single',
        label: 'Single full court',
        description: 'One court, no subdivisions.',
        defaultDurationMinutes: 120,
        nodes: [{ key: 'full', name: 'Full Court', kind: 'court', capacity: 10 }],
      },
    ],
  },
  {
    sport: 'tennis',
    emoji: '🎾',
    label: 'Tennis',
    presets: [
      {
        id: 'tennis-flat',
        label: 'N courts',
        description: 'Independent flat courts. Common for tennis clubs.',
        defaultDurationMinutes: 60,
        nodes: [],
        variableCount: { min: 1, max: 24, default: 4, namePattern: 'Court {n}' },
      },
    ],
  },
  {
    sport: 'pickleball',
    emoji: '🥒',
    label: 'Pickleball',
    presets: [
      {
        id: 'pickleball-flat',
        label: 'N standalone courts',
        description: 'Dedicated pickleball courts.',
        defaultDurationMinutes: 60,
        nodes: [],
        variableCount: { min: 1, max: 32, default: 4, namePattern: 'Court {n}' },
      },
      {
        id: 'pickleball-derived',
        label: 'M tennis courts × 4 pickleball',
        description: 'Each tennis court hosts 4 pickleball courts. Booking any pickleball court locks the tennis parent.',
        defaultDurationMinutes: 60,
        nodes: [],
        variableCount: { min: 1, max: 12, default: 1, namePattern: 'Tennis {n}' },
      },
    ],
  },
  {
    sport: 'volleyball',
    emoji: '🏐',
    label: 'Volleyball',
    presets: [
      {
        id: 'volleyball-flat',
        label: 'N courts',
        description: 'Independent courts.',
        defaultDurationMinutes: 120,
        nodes: [],
        variableCount: { min: 1, max: 12, default: 2, namePattern: 'Court {n}' },
      },
    ],
  },
  {
    sport: 'golf',
    emoji: '⛳',
    label: 'Golf',
    presets: [
      {
        // The only golf layout (owner decision C14): one tee sheet per course,
        // no driving range bays and no Front 9 / Back 9 split. Courts made
        // from the old presets keep working through their stored slotModel.
        id: 'golf-18',
        label: 'Golf course',
        description:
          'One tee sheet per course. Each tee time takes a single, twosome, threesome or foursome, paid per golfer. Golfers play 18 holes, or 9 holes when you set a 9 hole price.',
        defaultDurationMinutes: 10,
        bookingMode: 'shared',
        pricingMode: 'per_player',
        teeIntervalMinutes: 10,
        maxPlayers: 4,
        nodes: [{ key: 'course', name: 'Golf Course', kind: 'course', capacity: 4 }],
      },
    ],
  },
  {
    sport: 'badminton',
    emoji: '🏸',
    label: 'Badminton',
    presets: [
      {
        id: 'badminton-flat',
        label: 'N courts',
        description: 'Independent badminton courts.',
        defaultDurationMinutes: 60,
        nodes: [],
        variableCount: { min: 1, max: 24, default: 4, namePattern: 'Court {n}' },
      },
    ],
  },
  {
    sport: 'swimming',
    emoji: '🏊',
    label: 'Swimming',
    presets: [
      {
        id: 'swimming-lanes',
        label: 'N lap lanes',
        description: 'Independent lap lanes, booked per lane for a time block.',
        defaultDurationMinutes: 60,
        nodes: [],
        variableCount: { min: 1, max: 16, default: 6, namePattern: 'Lane {n}' },
      },
      {
        id: 'swimming-pool',
        label: 'Whole pool',
        description: 'Reserve the entire pool as one resource.',
        defaultDurationMinutes: 60,
        nodes: [{ key: 'pool', name: 'Pool', kind: 'court', capacity: 30 }],
      },
    ],
  },
  {
    sport: 'squash',
    emoji: '🟦',
    label: 'Squash',
    presets: [
      {
        id: 'squash-flat',
        label: 'N courts',
        description: 'Independent squash courts.',
        defaultDurationMinutes: 45,
        nodes: [],
        variableCount: { min: 1, max: 16, default: 4, namePattern: 'Court {n}' },
      },
    ],
  },
];

// Materialise a preset into actual nodes given a count (for variableCount presets).
export function materialisePreset(preset: CourtPreset, count?: number): PresetNode[] {
  if (preset.nodes.length > 0) return preset.nodes;
  if (!preset.variableCount) return [];
  const n = count ?? preset.variableCount.default;

  if (preset.id === 'pickleball-derived') {
    // Each tennis court parent gets 4 pickleball children.
    const out: PresetNode[] = [];
    for (let i = 1; i <= n; i++) {
      const tennisKey = `tennis-${i}`;
      out.push({ key: tennisKey, name: `Tennis ${i}`, kind: 'court', capacity: 4 });
      for (let j = 1; j <= 4; j++) {
        out.push({
          key: `pb-${i}-${j}`,
          name: `Tennis ${i} · PB ${j}`,
          kind: 'derived',
          capacity: 4,
          parentKey: tennisKey,
        });
      }
    }
    return out;
  }

  return Array.from({ length: n }, (_, i) => ({
    key: `c-${i + 1}`,
    name: preset.variableCount!.namePattern.replace('{n}', String(i + 1)),
    kind: 'court' as const,
    capacity: 4,
  }));
}

// Sport presets for the court-tree wizard at /onboarding/courts.
// Each preset describes a tree of courts the venue owner can adopt as a
// starting point. After picking, they can rename / reorder / set capacity
// before commit.

import type { VenueSport } from '@/lib/types/db';

export interface PresetNode {
  // Stable id within the preset so we can reference parent in children.
  key: string;
  name: string;
  // Free-text kind that becomes venue_courts.kind. Drives some UI hints
  // (e.g. half-pitch icon vs quarter icon) but isn't enum-checked.
  kind: 'pitch' | 'half' | 'quarter' | 'court' | 'derived';
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

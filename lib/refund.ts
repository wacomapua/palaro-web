// Refund tiers: the calculator, the labels and policy resolution. The tier
// walk matches cancel_venue_booking (Postgres) so the owner preview shows the
// refund the database will give; supabase/tests/refund_tier_walk.test.sql and
// tests/refund.test.mjs hold both to one table of cases. The labels follow
// contract C8, identical to team-manager's src/lib/refundPolicy.ts.
//
// Kept free of runtime imports so `node --test` can load it directly.

import type { RefundPolicy, RefundTier } from '@/lib/types/db';

// Postgres column default for venues.default_refund_policy.
export const DEFAULT_REFUND_POLICY: RefundPolicy = {
  tiers: [
    { hours_before: 48, refund_pct: 100 },
    { hours_before: 24, refund_pct: 50 },
    { hours_before: 0, refund_pct: 0 },
  ],
};

export interface RefundComputation {
  hoursBefore: number;
  refundPct: number;
  refundCents: number;
  feeKept: number;
}

// Sorted by hours_before descending (stable), with duplicate thresholds
// dropped, keeping the first after sorting. The editor saves policies in this
// form; the walk and the labels apply it to whatever they are given.
export function normalizeTiers(tiers: RefundTier[]): RefundTier[] {
  const sorted = [...tiers].sort((a, b) => b.hours_before - a.hours_before);
  return sorted.filter((t, i) => i === 0 || t.hours_before !== sorted[i - 1].hours_before);
}

// The policy a booking is refunded under: the snapshot taken when it was
// booked (owner decision 1), else the slot override, else the venue default.
// Same order as cancel_venue_booking.
export function resolveRefundPolicy(
  snapshot: RefundPolicy | null | undefined,
  slotPolicy: RefundPolicy | null | undefined,
  venuePolicy: RefundPolicy | null | undefined,
): RefundPolicy {
  return snapshot ?? slotPolicy ?? venuePolicy ?? DEFAULT_REFUND_POLICY;
}

export function computeRefund(
  totalCents: number,
  startsAt: Date | string,
  policy: RefundPolicy = DEFAULT_REFUND_POLICY,
  now: Date = new Date(),
): RefundComputation {
  const start = typeof startsAt === 'string' ? new Date(startsAt) : startsAt;
  const hoursBefore = (start.getTime() - now.getTime()) / 3_600_000;

  // Highest threshold first; the first one at or below hoursBefore wins, and
  // none matching means no refund (as in cancel_venue_booking).
  let pct = 0;
  for (const t of normalizeTiers(policy?.tiers ?? [])) {
    if (hoursBefore >= t.hours_before) {
      pct = t.refund_pct;
      break;
    }
  }

  const refundCents = Math.round((totalCents * pct) / 100);
  return {
    hoursBefore,
    refundPct: pct,
    refundCents,
    feeKept: totalCents - refundCents,
  };
}

type Window = { lo: number; hi: number; pct: number };

function pctText(pct: number): string {
  if (pct === 100) return 'full refund';
  if (pct === 0) return 'no refund';
  return `${pct}% refund`;
}

function windowLabel({ lo, hi, pct }: Window): string {
  const text = pctText(pct);
  if (lo > 0) return `${lo}h+ before · ${text}`;
  if (hi === Infinity) return `Any time · ${text}`;
  return `< ${hi}h · ${text}`;
}

// C8: each tier covers its own threshold up to the next higher one; below the
// lowest threshold nothing is refunded; adjacent windows with the same pct
// merge into one label.
export function formatRefundPolicy(policy: RefundPolicy | null | undefined): string[] {
  const tiers = normalizeTiers(policy?.tiers ?? []);

  const windows: Window[] = tiers.map((t, i) => ({
    lo: t.hours_before,
    hi: i === 0 ? Infinity : tiers[i - 1].hours_before,
    pct: t.refund_pct,
  }));

  // With no tiers at all this window is the whole range.
  const lowest = windows.length > 0 ? windows[windows.length - 1].lo : Infinity;
  if (lowest > 0) windows.push({ lo: 0, hi: lowest, pct: 0 });

  const merged: Window[] = [];
  for (const w of windows) {
    const prev = merged[merged.length - 1];
    if (prev && prev.pct === w.pct) prev.lo = w.lo;
    else merged.push({ ...w });
  }

  return merged.map(windowLabel);
}

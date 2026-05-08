// Refund-tier calculator. Same logic that lives in cancel_venue_booking
// (Postgres) — duplicated here so the UI can preview the refund amount
// before the captain commits to cancelling.

import type { RefundPolicy } from '@/lib/types/db';

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

export function computeRefund(
  totalCents: number,
  startsAt: Date | string,
  policy: RefundPolicy = DEFAULT_REFUND_POLICY,
  now: Date = new Date(),
): RefundComputation {
  const start = typeof startsAt === 'string' ? new Date(startsAt) : startsAt;
  const hoursBefore = (start.getTime() - now.getTime()) / 3_600_000;

  // Walk tiers (assumed sorted descending by hours_before). First whose
  // threshold <= hoursBefore wins.
  let pct = 0;
  for (const t of policy.tiers) {
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

export function formatRefundPolicy(policy: RefundPolicy = DEFAULT_REFUND_POLICY): string[] {
  return policy.tiers.map((t) =>
    t.refund_pct === 100
      ? `${t.hours_before}h+ before · full refund`
      : t.refund_pct === 0
        ? `< ${t.hours_before === 0 ? 24 : t.hours_before}h · no refund`
        : `${t.hours_before}h+ before · ${t.refund_pct}% refund`,
  );
}

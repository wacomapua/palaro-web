'use client';

import { Plus, Trash2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import type { RefundPolicy, RefundTier } from '@/lib/types/db';

// computeRefund() walks tiers assuming they're sorted descending by
// hours_before (first threshold <= hoursBefore wins). Editing can leave them in
// any order, so normalize before persisting.
export function normalizeTiers(tiers: RefundTier[]): RefundTier[] {
  return [...tiers].sort((a, b) => b.hours_before - a.hours_before);
}

/**
 * Editable list of refund tiers ("Nh+ before → X% refund"). Shared by the
 * venue-default policy editor (settings) and the per-slot override (calendar).
 * Purely controlled — persistence and preview live in the parent.
 */
export function RefundPolicyEditor({
  value,
  onChange,
  disabled,
}: {
  value: RefundPolicy;
  onChange: (next: RefundPolicy) => void;
  disabled?: boolean;
}) {
  const tiers = value.tiers;

  function update(i: number, patch: Partial<RefundTier>) {
    onChange({ tiers: tiers.map((t, idx) => (idx === i ? { ...t, ...patch } : t)) });
  }
  function remove(i: number) {
    onChange({ tiers: tiers.filter((_, idx) => idx !== i) });
  }
  function add() {
    onChange({ tiers: [...tiers, { hours_before: 0, refund_pct: 0 }] });
  }

  return (
    <div className="space-y-3">
      <div className="space-y-2">
        {tiers.map((t, i) => (
          <div key={i} className="flex items-center gap-2">
            <Input
              type="number"
              min={0}
              value={String(t.hours_before)}
              onChange={(e) =>
                update(i, { hours_before: Math.max(0, Math.round(Number(e.target.value) || 0)) })
              }
              disabled={disabled}
              className="w-20"
              aria-label="Hours before start"
            />
            <span className="whitespace-nowrap text-sm text-ink-dim">h+ before →</span>
            <Input
              type="number"
              min={0}
              max={100}
              value={String(t.refund_pct)}
              onChange={(e) =>
                update(i, {
                  refund_pct: Math.min(100, Math.max(0, Math.round(Number(e.target.value) || 0))),
                })
              }
              disabled={disabled}
              className="w-20"
              aria-label="Refund percent"
            />
            <span className="whitespace-nowrap text-sm text-ink-dim">% refund</span>
            <Button
              variant="ghost"
              size="icon"
              onClick={() => remove(i)}
              disabled={disabled || tiers.length <= 1}
              title="Remove tier"
              className="ml-auto"
            >
              <Trash2 className="h-3.5 w-3.5" />
            </Button>
          </div>
        ))}
      </div>
      <Button variant="outline" size="sm" onClick={add} disabled={disabled}>
        <Plus className="h-4 w-4" />
        Add tier
      </Button>
    </div>
  );
}

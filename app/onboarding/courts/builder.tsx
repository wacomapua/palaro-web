'use client';

import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { ChevronRight } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { createClient } from '@/lib/supabase/client';
import {
  SPORT_CONFIGS,
  materialisePreset,
  type CourtPreset,
  type PresetNode,
} from '@/lib/sport-presets';
import type { VenueSport } from '@/lib/types/db';

interface ExistingCourt {
  id: string;
  name: string;
  kind: string | null;
  parent_court_id: string | null;
  sort_order: number;
}

type DraftNode = PresetNode;

export function CourtsBuilder({
  venueId,
  venueSport,
  existingCourts,
}: {
  venueId: string;
  venueSport: VenueSport;
  existingCourts: ExistingCourt[];
}) {
  const router = useRouter();
  const sportConfig = SPORT_CONFIGS.find((c) => c.sport === venueSport)!;
  const [presetId, setPresetId] = useState<string>(sportConfig.presets[0].id);
  const preset = sportConfig.presets.find((p) => p.id === presetId)!;
  const [count, setCount] = useState<number>(preset.variableCount?.default ?? 1);
  const [draft, setDraft] = useState<DraftNode[]>(() => materialisePreset(preset, count));
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const alreadySetUp = existingCourts.length > 0;

  function selectPreset(p: CourtPreset) {
    setPresetId(p.id);
    const c = p.variableCount?.default ?? 1;
    setCount(c);
    setDraft(materialisePreset(p, c));
  }

  function setCountAndRegenerate(n: number) {
    setCount(n);
    setDraft(materialisePreset(preset, n));
  }

  function renameNode(key: string, name: string) {
    setDraft((d) => d.map((n) => (n.key === key ? { ...n, name } : n)));
  }

  // Group nodes into a renderable tree (root → children).
  const tree = useMemo(() => buildTree(draft), [draft]);

  async function commit() {
    if (alreadySetUp) {
      router.push('/onboarding/payout');
      return;
    }
    setSubmitting(true);
    setError(null);

    const supabase = createClient();

    // Insert pass 1: all roots (parent_court_id = null) so we can map keys → ids.
    const keyToId: Record<string, string> = {};
    const roots = draft.filter((n) => !n.parentKey);

    for (let i = 0; i < roots.length; i++) {
      const n = roots[i];
      const { data, error: insErr } = await supabase
        .from('venue_courts')
        .insert({
          venue_id: venueId,
          parent_court_id: null,
          name: n.name,
          kind: n.kind,
          sort_order: i,
        })
        .select('id')
        .single();
      if (insErr || !data) {
        setError(insErr?.message ?? 'Failed to create court');
        setSubmitting(false);
        return;
      }
      keyToId[n.key] = data.id as string;
    }

    // Insert pass 2: children, breadth-first, until all done. Multiple passes
    // handle deeper trees (e.g. Football full → halves → quarters).
    let remaining = draft.filter((n) => n.parentKey);
    let pass = 0;
    while (remaining.length > 0 && pass < 5) {
      const insertable = remaining.filter((n) => keyToId[n.parentKey!]);
      for (let i = 0; i < insertable.length; i++) {
        const n = insertable[i];
        const { data, error: insErr } = await supabase
          .from('venue_courts')
          .insert({
            venue_id: venueId,
            parent_court_id: keyToId[n.parentKey!],
            name: n.name,
            kind: n.kind,
            sort_order: i,
          })
          .select('id')
          .single();
        if (insErr || !data) {
          setError(insErr?.message ?? 'Failed to create child court');
          setSubmitting(false);
          return;
        }
        keyToId[n.key] = data.id as string;
      }
      remaining = remaining.filter((n) => !keyToId[n.key]);
      pass++;
    }

    if (remaining.length > 0) {
      setError(`Could not place ${remaining.length} court(s) — parent reference missing`);
      setSubmitting(false);
      return;
    }

    router.push('/onboarding/payout');
  }

  if (alreadySetUp) {
    return (
      <div className="card-base p-6">
        <p className="text-sm text-ink">
          You already have {existingCourts.length} court{existingCourts.length === 1 ? '' : 's'}{' '}
          set up. Edit them from settings if you need to change the layout.
        </p>
        <div className="mt-4 flex justify-between">
          <Button variant="ghost" onClick={() => router.push('/onboarding/venue')}>
            Back
          </Button>
          <Button onClick={() => router.push('/onboarding/payout')}>Continue to payout</Button>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Preset picker */}
      <div className="space-y-3">
        <Label>Pick a layout</Label>
        <div className="grid gap-3">
          {sportConfig.presets.map((p) => {
            const active = p.id === presetId;
            return (
              <button
                type="button"
                key={p.id}
                onClick={() => selectPreset(p)}
                className={`text-left rounded-lg border p-4 transition-colors ${
                  active
                    ? 'border-brand bg-brand/5'
                    : 'border-line/70 bg-bg-1 hover:border-line'
                }`}
              >
                <div className="flex items-center justify-between">
                  <span className="text-sm font-medium text-ink">{p.label}</span>
                  {active && <Badge tone="brand">Selected</Badge>}
                </div>
                <p className="mt-1 text-xs text-ink-dim">{p.description}</p>
              </button>
            );
          })}
        </div>
      </div>

      {preset.variableCount && (
        <div className="space-y-1.5">
          <Label>How many?</Label>
          <Input
            type="number"
            min={preset.variableCount.min}
            max={preset.variableCount.max}
            value={count}
            onChange={(e) => setCountAndRegenerate(Number(e.target.value) || 1)}
            className="w-32"
          />
        </div>
      )}

      {/* Tree preview */}
      <div className="card-base p-5">
        <div className="mb-3 flex items-center justify-between text-xs text-ink-dim">
          <span>{draft.length} courts will be created</span>
          <span className="font-mono">Default {preset.defaultDurationMinutes} min slots</span>
        </div>

        {/* Column header */}
        <div className="mb-2 flex items-center gap-2 px-1 text-[10px] uppercase tracking-[0.18em] text-ink-mute">
          <span className="flex-1">Court name</span>
          <span className="w-[72px] text-center">Type</span>
        </div>

        <ul className="space-y-1">
          {tree.map((root) => (
            <NodeRow key={root.key} node={root} depth={0} renameNode={renameNode} />
          ))}
        </ul>

        <p className="mt-3 text-[11px] text-ink-mute">
          Booking a parent locks its children — if a captain books the Full Pitch,
          the halves and quarters become unavailable for that timeblock.
        </p>
      </div>

      {error && <p className="text-xs text-danger">{error}</p>}

      <div className="flex justify-between">
        <Button variant="ghost" onClick={() => router.push('/onboarding/venue')}>
          Back
        </Button>
        <Button onClick={commit} disabled={submitting || draft.length === 0}>
          {submitting ? 'Creating courts…' : 'Save courts & continue'}
        </Button>
      </div>
    </div>
  );
}

interface TreeNode extends DraftNode {
  children: TreeNode[];
}

function buildTree(nodes: DraftNode[]): TreeNode[] {
  const byKey = new Map<string, TreeNode>();
  nodes.forEach((n) => byKey.set(n.key, { ...n, children: [] }));
  const roots: TreeNode[] = [];
  byKey.forEach((node) => {
    if (node.parentKey && byKey.has(node.parentKey)) {
      byKey.get(node.parentKey)!.children.push(node);
    } else {
      roots.push(node);
    }
  });
  return roots;
}

function NodeRow({
  node,
  depth,
  renameNode,
}: {
  node: TreeNode;
  depth: number;
  renameNode: (key: string, name: string) => void;
}) {
  return (
    <>
      <li className="flex items-center gap-2" style={{ paddingLeft: depth * 18 }}>
        {depth > 0 && (
          <span className="text-ink-mute">
            <ChevronRight className="h-3 w-3" />
          </span>
        )}
        <Input
          value={node.name}
          onChange={(e) => renameNode(node.key, e.target.value)}
          className="h-8 flex-1 text-[13px]"
        />
        <Badge tone="neutral" className="w-[72px] justify-center font-mono uppercase">
          {node.kind}
        </Badge>
      </li>
      {node.children.map((c) => (
        <NodeRow key={c.key} node={c} depth={depth + 1} renameNode={renameNode} />
      ))}
    </>
  );
}

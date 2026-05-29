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
  slotModelForPreset,
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

interface SportDraft {
  presetId: string;
  count: number;
  draft: DraftNode[];
}

function initialDraftFor(sport: VenueSport): SportDraft {
  const cfg = SPORT_CONFIGS.find((c) => c.sport === sport)!;
  const preset = cfg.presets[0];
  const count = preset.variableCount?.default ?? 1;
  return { presetId: preset.id, count, draft: materialisePreset(preset, count) };
}

export function CourtsBuilder({
  venueId,
  sports,
  existingCourts,
}: {
  venueId: string;
  sports: VenueSport[];
  existingCourts: ExistingCourt[];
}) {
  const router = useRouter();
  const [activeSport, setActiveSport] = useState<VenueSport>(sports[0]);
  const [drafts, setDrafts] = useState<Record<string, SportDraft>>(() =>
    Object.fromEntries(sports.map((s) => [s, initialDraftFor(s)])),
  );
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const alreadySetUp = existingCourts.length > 0;

  const sportConfig = SPORT_CONFIGS.find((c) => c.sport === activeSport)!;
  const current = drafts[activeSport];
  const preset = sportConfig.presets.find((p) => p.id === current.presetId)!;

  function patchActive(patch: Partial<SportDraft>) {
    setDrafts((d) => ({ ...d, [activeSport]: { ...d[activeSport], ...patch } }));
  }

  function selectPreset(p: CourtPreset) {
    const c = p.variableCount?.default ?? 1;
    patchActive({ presetId: p.id, count: c, draft: materialisePreset(p, c) });
  }

  function setCountAndRegenerate(n: number) {
    patchActive({ count: n, draft: materialisePreset(preset, n) });
  }

  function renameNode(key: string, name: string) {
    patchActive({ draft: current.draft.map((n) => (n.key === key ? { ...n, name } : n)) });
  }

  const tree = useMemo(() => buildTree(current.draft), [current.draft]);
  const totalCourts = useMemo(
    () => sports.reduce((sum, s) => sum + drafts[s].draft.length, 0),
    [sports, drafts],
  );

  async function commit() {
    if (alreadySetUp) {
      router.push('/onboarding/payout');
      return;
    }
    setSubmitting(true);
    setError(null);

    const supabase = createClient();
    let sortOrder = 0;

    // Insert sport by sport so courts stay grouped, parents before children.
    for (const sport of sports) {
      const sportCfg = SPORT_CONFIGS.find((c) => c.sport === sport)!;
      const { draft, presetId } = drafts[sport];
      const sportPreset = sportCfg.presets.find((p) => p.id === presetId)!;
      const slotModel = slotModelForPreset(sportPreset);
      const keyToId: Record<string, string> = {};

      async function insertNode(n: DraftNode, parentId: string | null) {
        const { data, error: insErr } = await supabase
          .from('venue_courts')
          .insert({
            venue_id: venueId,
            parent_court_id: parentId,
            sport,
            name: n.name,
            kind: n.kind,
            capacity: n.capacity ?? null,
            sort_order: sortOrder++,
            metadata: { slotModel } as unknown as import('@/lib/types/db').Json,
          })
          .select('id')
          .single();
        if (insErr || !data) {
          throw new Error(insErr?.message ?? 'Failed to create court');
        }
        keyToId[n.key] = data.id as string;
      }

      try {
        // Roots first.
        for (const n of draft.filter((x) => !x.parentKey)) {
          await insertNode(n, null);
        }
        // Then descendants, breadth-first across a few passes for deep trees.
        let remaining = draft.filter((x) => x.parentKey);
        let pass = 0;
        while (remaining.length > 0 && pass < 5) {
          const insertable = remaining.filter((n) => keyToId[n.parentKey!]);
          for (const n of insertable) {
            await insertNode(n, keyToId[n.parentKey!]);
          }
          remaining = remaining.filter((n) => !keyToId[n.key]);
          pass++;
        }
        if (remaining.length > 0) {
          throw new Error(
            `Could not place ${remaining.length} ${sport} court(s) — parent reference missing`,
          );
        }
      } catch (e) {
        setError(e instanceof Error ? e.message : 'Failed to create courts');
        setSubmitting(false);
        return;
      }
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

  const isTeeSheet = !!preset.teeIntervalMinutes;

  return (
    <div className="space-y-6">
      {/* Sport tabs — only when the venue runs more than one sport */}
      {sports.length > 1 && (
        <div className="flex flex-wrap gap-2">
          {sports.map((s) => {
            const cfg = SPORT_CONFIGS.find((c) => c.sport === s)!;
            const active = s === activeSport;
            const n = drafts[s].draft.length;
            return (
              <button
                type="button"
                key={s}
                onClick={() => setActiveSport(s)}
                className={`inline-flex items-center gap-1.5 rounded-md border px-3 py-2 text-sm transition-colors ${
                  active
                    ? 'border-brand bg-brand/10 text-brand'
                    : 'border-line/70 bg-bg-1 text-ink-dim hover:border-line'
                }`}
              >
                <span>{cfg.emoji}</span>
                {cfg.label}
                <Badge tone="neutral" className="ml-1 font-mono">{n}</Badge>
              </button>
            );
          })}
        </div>
      )}

      {/* Preset picker */}
      <div className="space-y-3">
        <Label>Pick a layout for {sportConfig.label}</Label>
        <div className="grid gap-3">
          {sportConfig.presets.map((p) => {
            const active = p.id === current.presetId;
            return (
              <button
                type="button"
                key={p.id}
                onClick={() => selectPreset(p)}
                className={`text-left rounded-lg border p-4 transition-colors ${
                  active ? 'border-brand bg-brand/5' : 'border-line/70 bg-bg-1 hover:border-line'
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
            value={current.count}
            onChange={(e) => setCountAndRegenerate(Number(e.target.value) || 1)}
            className="w-32"
          />
        </div>
      )}

      {/* Tree preview */}
      <div className="card-base p-5">
        <div className="mb-3 flex items-center justify-between text-xs text-ink-dim">
          <span>{current.draft.length} {sportConfig.label} courts will be created</span>
          <span className="font-mono">
            {isTeeSheet
              ? `Tee times · every ${preset.teeIntervalMinutes} min · up to ${preset.maxPlayers} players`
              : `Default ${preset.defaultDurationMinutes} min slots`}
          </span>
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
          {isTeeSheet
            ? 'Golf tee times are shared: up to a foursome books each time, priced per golfer. You generate the tee sheet from the calendar.'
            : 'Booking a parent locks its children — if a captain books the Full Pitch, the halves and quarters become unavailable for that timeblock.'}
        </p>
      </div>

      {error && <p className="text-xs text-danger">{error}</p>}

      <div className="flex items-center justify-between">
        <Button variant="ghost" onClick={() => router.push('/onboarding/venue')}>
          Back
        </Button>
        <div className="flex items-center gap-3">
          {sports.length > 1 && (
            <span className="text-xs text-ink-mute">{totalCourts} courts total</span>
          )}
          <Button onClick={commit} disabled={submitting || totalCourts === 0}>
            {submitting ? 'Creating courts…' : 'Save courts & continue'}
          </Button>
        </div>
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

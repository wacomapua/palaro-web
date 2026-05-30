'use client';

import { useMemo, useRef, useState } from 'react';
import { ChevronRight, Plus, X } from 'lucide-react';
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
import type { VenueSport, Json } from '@/lib/types/db';

// One "layout" the owner has added for a sport (e.g. an 18-hole course, OR a
// driving range, OR N tennis courts). A sport can have many — a golf venue can
// stack two courses + a range; a club can have a full pitch + 5-a-side courts.
interface LayoutInstance {
  id: string;
  presetId: string;
  presetLabel: string;
  count: number; // for variableCount presets
  variable: boolean;
  nodes: PresetNode[]; // re-keyed so keys are unique across instances
}

// Namespace a preset's node keys/parentKeys to this instance so several
// instances of the same preset don't collide.
function rekey(nodes: PresetNode[], instId: string): PresetNode[] {
  return nodes.map((n) => ({
    ...n,
    key: `${instId}__${n.key}`,
    parentKey: n.parentKey ? `${instId}__${n.parentKey}` : undefined,
  }));
}

// Suffix root names when a sport already has an instance of the same preset
// ("18-Hole Course", "18-Hole Course 2", …) — fully renamable afterward.
function autoName(nodes: PresetNode[], dupIndex: number): PresetNode[] {
  if (dupIndex === 0) return nodes;
  return nodes.map((n) => (n.parentKey ? n : { ...n, name: `${n.name} ${dupIndex + 1}` }));
}

function buildInstance(
  id: string,
  preset: CourtPreset,
  dupIndex: number,
  count?: number,
): LayoutInstance {
  const c = count ?? preset.variableCount?.default ?? 1;
  const nodes = autoName(rekey(materialisePreset(preset, c), id), dupIndex);
  return {
    id,
    presetId: preset.id,
    presetLabel: preset.label,
    count: c,
    variable: !!preset.variableCount,
    nodes,
  };
}

export function CourtLayoutBuilder({
  venueId,
  sports,
  startSortOrder = 0,
  seedDefaults = false,
  submitLabel = 'Save courts',
  onCommitted,
  secondaryAction,
}: {
  venueId: string;
  sports: VenueSport[];
  startSortOrder?: number;
  seedDefaults?: boolean;
  submitLabel?: string;
  onCommitted: () => void;
  secondaryAction?: React.ReactNode;
}) {
  const idSeq = useRef(0);
  const [activeSport, setActiveSport] = useState<VenueSport>(sports[0]);
  const [layouts, setLayouts] = useState<Record<string, LayoutInstance[]>>(() => {
    const init: Record<string, LayoutInstance[]> = {};
    for (const s of sports) {
      const cfg = SPORT_CONFIGS.find((c) => c.sport === s)!;
      init[s] = seedDefaults ? [buildInstance(`seed-${s}`, cfg.presets[0], 0)] : [];
    }
    return init;
  });
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const sportConfig = SPORT_CONFIGS.find((c) => c.sport === activeSport)!;
  const sportLayouts = layouts[activeSport] ?? [];

  function addLayout(preset: CourtPreset) {
    const dupIndex = sportLayouts.filter((l) => l.presetId === preset.id).length;
    const inst = buildInstance(`add-${idSeq.current++}`, preset, dupIndex);
    setLayouts((m) => ({ ...m, [activeSport]: [...(m[activeSport] ?? []), inst] }));
  }

  function removeLayout(instId: string) {
    setLayouts((m) => ({ ...m, [activeSport]: m[activeSport].filter((l) => l.id !== instId) }));
  }

  function setCount(instId: string, n: number) {
    setLayouts((m) => {
      const list = m[activeSport];
      const dupIndex = list.filter((x) => x.presetId === list.find((y) => y.id === instId)!.presetId)
        .findIndex((x) => x.id === instId);
      return {
        ...m,
        [activeSport]: list.map((l) => {
          if (l.id !== instId) return l;
          const preset = sportConfig.presets.find((p) => p.id === l.presetId)!;
          return buildInstance(l.id, preset, Math.max(0, dupIndex), Math.max(1, n));
        }),
      };
    });
  }

  function renameNode(instId: string, key: string, name: string) {
    setLayouts((m) => ({
      ...m,
      [activeSport]: m[activeSport].map((l) =>
        l.id === instId
          ? { ...l, nodes: l.nodes.map((nd) => (nd.key === key ? { ...nd, name } : nd)) }
          : l,
      ),
    }));
  }

  const totalCourts = useMemo(
    () =>
      sports.reduce(
        (sum, s) => sum + (layouts[s]?.reduce((a, l) => a + l.nodes.length, 0) ?? 0),
        0,
      ),
    [sports, layouts],
  );

  async function commit() {
    setSubmitting(true);
    setError(null);
    const supabase = createClient();
    let sortOrder = startSortOrder;

    try {
      for (const sport of sports) {
        for (const inst of layouts[sport] ?? []) {
          const preset = SPORT_CONFIGS.find((c) => c.sport === sport)!.presets.find(
            (p) => p.id === inst.presetId,
          )!;
          const slotModel = slotModelForPreset(preset);
          const keyToId: Record<string, string> = {};

          const insertNode = async (n: PresetNode, parentId: string | null) => {
            const { data, error: e } = await supabase
              .from('venue_courts')
              .insert({
                venue_id: venueId,
                parent_court_id: parentId,
                sport,
                name: n.name,
                kind: n.kind,
                capacity: n.capacity ?? null,
                sort_order: sortOrder++,
                metadata: { slotModel } as unknown as Json,
              })
              .select('id')
              .single();
            if (e || !data) throw new Error(e?.message ?? 'Failed to create court');
            keyToId[n.key] = data.id as string;
          };

          for (const n of inst.nodes.filter((x) => !x.parentKey)) await insertNode(n, null);
          let remaining = inst.nodes.filter((x) => x.parentKey);
          let pass = 0;
          while (remaining.length > 0 && pass < 6) {
            for (const n of remaining.filter((n) => keyToId[n.parentKey!])) {
              await insertNode(n, keyToId[n.parentKey!]);
            }
            remaining = remaining.filter((n) => !keyToId[n.key]);
            pass++;
          }
          if (remaining.length > 0) {
            throw new Error('Could not place some courts — parent reference missing');
          }
        }
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to create courts');
      setSubmitting(false);
      return;
    }

    setSubmitting(false);
    onCommitted();
  }

  return (
    <div className="space-y-6">
      {/* Sport tabs — only when the venue runs more than one sport */}
      {sports.length > 1 && (
        <div className="flex flex-wrap gap-2">
          {sports.map((s) => {
            const cfg = SPORT_CONFIGS.find((c) => c.sport === s)!;
            const n = layouts[s]?.reduce((a, l) => a + l.nodes.length, 0) ?? 0;
            return (
              <button
                type="button"
                key={s}
                onClick={() => setActiveSport(s)}
                className={`inline-flex items-center gap-1.5 rounded-md border px-3 py-2 text-sm transition-colors ${
                  s === activeSport
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

      {/* Preset add-buttons */}
      <div className="space-y-3">
        <Label>Add a layout for {sportConfig.label}</Label>
        <div className="grid gap-3">
          {sportConfig.presets.map((p) => (
            <button
              type="button"
              key={p.id}
              onClick={() => addLayout(p)}
              className="group text-left rounded-lg border border-line/70 bg-bg-1 p-4 transition-colors hover:border-brand hover:bg-brand/5"
            >
              <div className="flex items-center justify-between">
                <span className="text-sm font-medium text-ink">{p.label}</span>
                <span className="inline-flex items-center gap-1 text-xs text-ink-dim group-hover:text-brand">
                  <Plus className="h-3.5 w-3.5" /> Add
                </span>
              </div>
              <p className="mt-1 text-xs text-ink-dim">{p.description}</p>
            </button>
          ))}
        </div>
        <p className="text-xs text-ink-mute">
          Add as many as your venue has — e.g. two 18-hole courses plus a driving range, or a
          full pitch plus separate 5-a-side courts.
        </p>
      </div>

      {/* Added layouts for the active sport */}
      {sportLayouts.length === 0 ? (
        <div className="card-base p-5 text-center text-sm text-ink-dim">
          No {sportConfig.label} layouts yet — add one above.
        </div>
      ) : (
        <div className="space-y-3">
          {sportLayouts.map((inst) => {
            const preset = sportConfig.presets.find((p) => p.id === inst.presetId)!;
            const isTee = !!preset.teeIntervalMinutes;
            const tree = buildTree(inst.nodes);
            return (
              <div key={inst.id} className="card-base p-5">
                <div className="mb-3 flex items-start justify-between gap-3">
                  <div>
                    <p className="text-sm font-medium text-ink">{inst.presetLabel}</p>
                    <p className="mt-0.5 text-[11px] font-mono text-ink-mute">
                      {inst.nodes.length} court{inst.nodes.length === 1 ? '' : 's'} ·{' '}
                      {isTee
                        ? `tee times every ${preset.teeIntervalMinutes} min · up to ${preset.maxPlayers}`
                        : `${preset.defaultDurationMinutes} min slots`}
                    </p>
                  </div>
                  <div className="flex items-center gap-2">
                    {inst.variable && preset.variableCount && (
                      <div className="flex items-center gap-1.5">
                        <Label className="text-[11px] text-ink-mute">Qty</Label>
                        <Input
                          type="number"
                          min={preset.variableCount.min}
                          max={preset.variableCount.max}
                          value={inst.count}
                          onChange={(e) => setCount(inst.id, Number(e.target.value) || 1)}
                          className="h-8 w-20"
                        />
                      </div>
                    )}
                    <Button
                      type="button"
                      variant="ghost"
                      size="icon"
                      onClick={() => removeLayout(inst.id)}
                      title="Remove this layout"
                    >
                      <X className="h-4 w-4" />
                    </Button>
                  </div>
                </div>
                <ul className="space-y-1">
                  {tree.map((root) => (
                    <NodeRow
                      key={root.key}
                      node={root}
                      depth={0}
                      onRename={(key, name) => renameNode(inst.id, key, name)}
                    />
                  ))}
                </ul>
              </div>
            );
          })}
        </div>
      )}

      {error && <p className="text-xs text-danger">{error}</p>}

      <div className="flex items-center justify-between">
        <div>{secondaryAction}</div>
        <div className="flex items-center gap-3">
          <span className="text-xs text-ink-mute">
            {totalCourts} court{totalCourts === 1 ? '' : 's'} total
          </span>
          <Button onClick={commit} disabled={submitting || totalCourts === 0}>
            {submitting ? 'Saving…' : submitLabel}
          </Button>
        </div>
      </div>
    </div>
  );
}

interface TreeNode extends PresetNode {
  children: TreeNode[];
}

function buildTree(nodes: PresetNode[]): TreeNode[] {
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
  onRename,
}: {
  node: TreeNode;
  depth: number;
  onRename: (key: string, name: string) => void;
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
          onChange={(e) => onRename(node.key, e.target.value)}
          className="h-8 flex-1 text-[13px]"
        />
        <Badge tone="neutral" className="w-[72px] justify-center font-mono uppercase">
          {node.kind}
        </Badge>
      </li>
      {node.children.map((c) => (
        <NodeRow key={c.key} node={c} depth={depth + 1} onRename={onRename} />
      ))}
    </>
  );
}

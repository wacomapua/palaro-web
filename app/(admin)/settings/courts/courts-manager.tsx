'use client';

import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { ArrowDown, ArrowUp, Check, ChevronRight, Pencil, Plus, Power, Trash2, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { createClient } from '@/lib/supabase/client';
import { CourtLayoutBuilder } from '@/components/court-layout-builder';
import { SPORT_CONFIGS } from '@/lib/sport-presets';
import type { VenueSport } from '@/lib/types/db';

interface Court {
  id: string;
  venue_id: string;
  parent_court_id: string | null;
  sport: VenueSport;
  name: string;
  kind: string | null;
  capacity: number | null;
  active: boolean;
  sort_order: number;
}

interface CourtTreeNode extends Court {
  children: CourtTreeNode[];
}

const SPORT_META = Object.fromEntries(SPORT_CONFIGS.map((c) => [c.sport, c]));

export function CourtsManager({
  venueId,
  sports,
  courts,
  maxSortOrder,
}: {
  venueId: string;
  sports: VenueSport[];
  courts: Court[];
  maxSortOrder: number;
}) {
  const router = useRouter();
  const [adding, setAdding] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Group courts into trees, bucketed by sport (roots carry the sport).
  const bySport = useMemo(() => {
    const byId = new Map<string, CourtTreeNode>();
    courts.forEach((c) => byId.set(c.id, { ...c, children: [] }));
    const roots: CourtTreeNode[] = [];
    byId.forEach((n) => {
      if (n.parent_court_id && byId.has(n.parent_court_id)) {
        byId.get(n.parent_court_id)!.children.push(n);
      } else {
        roots.push(n);
      }
    });
    const map = new Map<VenueSport, CourtTreeNode[]>();
    for (const r of roots.sort((a, b) => a.sort_order - b.sort_order)) {
      const arr = map.get(r.sport) ?? [];
      arr.push(r);
      map.set(r.sport, arr);
    }
    return map;
  }, [courts]);

  // Show every sport that actually has courts — offered ones first (in order),
  // then any whose offering was turned off but still has courts (so they stay
  // manageable instead of being stranded/hidden).
  const displaySports = useMemo(() => {
    const offered = sports.filter((s) => bySport.has(s));
    const stranded = [...bySport.keys()].filter((s) => !sports.includes(s));
    return [...offered, ...stranded];
  }, [sports, bySport]);

  async function toggleActive(court: Court) {
    setBusyId(court.id);
    setError(null);
    const supabase = createClient();
    const { error: e } = await supabase
      .from('venue_courts')
      .update({ active: !court.active })
      .eq('id', court.id);
    setBusyId(null);
    if (e) {
      setError(e.message);
      return;
    }
    router.refresh();
  }

  async function rename(court: Court, name: string) {
    const trimmed = name.trim();
    if (!trimmed || trimmed === court.name) return;
    setBusyId(court.id);
    setError(null);
    const supabase = createClient();
    const { error: e } = await supabase
      .from('venue_courts')
      .update({ name: trimmed })
      .eq('id', court.id);
    setBusyId(null);
    if (e) {
      setError(e.message);
      return;
    }
    router.refresh();
  }

  // Move a court up/down among its siblings (same parent, same sport). We
  // reassign the whole sibling group to sequential sort_order so it stays
  // correct even when legacy rows share values; only changed rows are written.
  async function move(court: Court, dir: -1 | 1) {
    const siblings = courts
      .filter((c) => c.parent_court_id === court.parent_court_id && c.sport === court.sport)
      .sort((a, b) => a.sort_order - b.sort_order);
    const idx = siblings.findIndex((c) => c.id === court.id);
    const target = idx + dir;
    if (idx < 0 || target < 0 || target >= siblings.length) return;

    const reordered = [...siblings];
    [reordered[idx], reordered[target]] = [reordered[target], reordered[idx]];
    const writes = reordered
      .map((c, i) => ({ id: c.id, sort_order: i, prev: c.sort_order }))
      .filter((w) => w.sort_order !== w.prev);

    setBusyId(court.id);
    setError(null);
    const supabase = createClient();
    for (const w of writes) {
      const { error: e } = await supabase
        .from('venue_courts')
        .update({ sort_order: w.sort_order })
        .eq('id', w.id);
      if (e) {
        setBusyId(null);
        setError(e.message);
        return;
      }
    }
    setBusyId(null);
    router.refresh();
  }

  async function remove(court: CourtTreeNode) {
    if (court.children.length > 0) {
      setError(`"${court.name}" has sub-courts — remove or deactivate those first.`);
      return;
    }
    if (!confirm(`Delete "${court.name}"? This can't be undone.`)) return;
    setBusyId(court.id);
    setError(null);
    const supabase = createClient();
    const { error: e } = await supabase.from('venue_courts').delete().eq('id', court.id);
    setBusyId(null);
    if (e) {
      // Most likely a foreign-key from existing slots/bookings.
      setError(
        `Couldn't delete "${court.name}" — it likely has slots or bookings. Deactivate it instead.`,
      );
      return;
    }
    router.refresh();
  }

  return (
    <div className="space-y-8">
      {/* Existing courts grouped by sport */}
      {courts.length === 0 ? (
        <div className="card-base p-6 text-sm text-ink-dim">No courts yet. Add some below.</div>
      ) : (
        <div className="space-y-5">
          {displaySports.map((sport) => {
              const cfg = SPORT_META[sport];
              return (
                <div key={sport} className="card-base p-5">
                  <div className="mb-3 flex items-center gap-2 text-sm font-medium text-ink">
                    <span>{cfg?.emoji}</span>
                    {cfg?.label ?? sport}
                  </div>
                  <ul className="space-y-1">
                    {(bySport.get(sport) ?? []).map((root, i, arr) => (
                      <CourtRow
                        key={root.id}
                        node={root}
                        depth={0}
                        index={i}
                        siblingCount={arr.length}
                        busyId={busyId}
                        onToggle={toggleActive}
                        onRemove={remove}
                        onRename={rename}
                        onMove={move}
                      />
                    ))}
                  </ul>
                </div>
              );
            })}
        </div>
      )}

      {error && <p className="text-xs text-danger">{error}</p>}

      {/* Add new layouts */}
      {adding ? (
        <div className="card-base p-5">
          <div className="mb-4 flex items-center justify-between">
            <h2 className="text-sm font-medium text-ink">Add courts</h2>
            <Button variant="ghost" size="sm" onClick={() => setAdding(false)}>
              Cancel
            </Button>
          </div>
          <CourtLayoutBuilder
            venueId={venueId}
            sports={sports}
            startSortOrder={maxSortOrder + 1}
            submitLabel="Add courts"
            onCommitted={() => {
              setAdding(false);
              router.refresh();
            }}
          />
        </div>
      ) : (
        <Button variant="outline" onClick={() => setAdding(true)}>
          <Plus className="h-4 w-4" />
          Add courts or a new layout
        </Button>
      )}
    </div>
  );
}

function CourtRow({
  node,
  depth,
  index,
  siblingCount,
  busyId,
  onToggle,
  onRemove,
  onRename,
  onMove,
}: {
  node: CourtTreeNode;
  depth: number;
  index: number;
  siblingCount: number;
  busyId: string | null;
  onToggle: (c: Court) => void;
  onRemove: (c: CourtTreeNode) => void;
  onRename: (c: Court, name: string) => void;
  onMove: (c: Court, dir: -1 | 1) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(node.name);
  const busy = busyId === node.id;

  function commit() {
    setEditing(false);
    onRename(node, draft);
  }
  function cancel() {
    setEditing(false);
    setDraft(node.name);
  }

  return (
    <>
      <li
        className="flex items-center gap-2 rounded-md py-1.5 pr-1 hover:bg-bg-1"
        style={{ paddingLeft: 4 + depth * 18 }}
      >
        {depth > 0 && <ChevronRight className="h-3 w-3 text-ink-mute" />}
        {editing ? (
          <div className="flex flex-1 items-center gap-1.5">
            <Input
              autoFocus
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') commit();
                if (e.key === 'Escape') cancel();
              }}
              className="h-7 flex-1 text-[13px]"
              aria-label="Court name"
            />
            <Button variant="ghost" size="icon" onClick={commit} disabled={busy} title="Save name">
              <Check className="h-3.5 w-3.5" />
            </Button>
            <Button variant="ghost" size="icon" onClick={cancel} disabled={busy} title="Cancel">
              <X className="h-3.5 w-3.5" />
            </Button>
          </div>
        ) : (
          <>
            <span
              className={`flex-1 truncate text-[13px] ${node.active ? 'text-ink' : 'text-ink-mute line-through'}`}
            >
              {node.name}
            </span>
            {node.kind && (
              <Badge tone="neutral" className="font-mono uppercase text-[10px]">
                {node.kind}
              </Badge>
            )}
            {node.capacity != null && (
              <Badge tone="neutral" className="font-mono text-[10px]">
                {node.capacity}
              </Badge>
            )}
            {!node.active && <Badge tone="warn">Inactive</Badge>}
            <Button
              variant="ghost"
              size="icon"
              disabled={busy || index === 0}
              onClick={() => onMove(node, -1)}
              title="Move up"
            >
              <ArrowUp className="h-3.5 w-3.5" />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              disabled={busy || index === siblingCount - 1}
              onClick={() => onMove(node, 1)}
              title="Move down"
            >
              <ArrowDown className="h-3.5 w-3.5" />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              disabled={busy}
              onClick={() => {
                setDraft(node.name);
                setEditing(true);
              }}
              title="Rename"
            >
              <Pencil className="h-3.5 w-3.5" />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              disabled={busy}
              onClick={() => onToggle(node)}
              title={node.active ? 'Deactivate' : 'Reactivate'}
            >
              <Power className={`h-3.5 w-3.5 ${node.active ? '' : 'text-ink-mute'}`} />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              disabled={busy}
              onClick={() => onRemove(node)}
              title="Delete"
            >
              <Trash2 className="h-3.5 w-3.5" />
            </Button>
          </>
        )}
      </li>
      {node.children.map((c, i, arr) => (
        <CourtRow
          key={c.id}
          node={c}
          depth={depth + 1}
          index={i}
          siblingCount={arr.length}
          busyId={busyId}
          onToggle={onToggle}
          onRemove={onRemove}
          onRename={onRename}
          onMove={onMove}
        />
      ))}
    </>
  );
}

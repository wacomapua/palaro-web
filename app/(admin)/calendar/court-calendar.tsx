'use client';

import { useMemo, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { ChevronLeft, ChevronRight, ChevronDown } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { cn } from '@/lib/cn';
import { formatMoney } from '@/lib/format';
import { addDaysYmd, ymdInTz, hourInTz, formatTimeInTz, formatYmd } from '@/lib/tz';
import { SPORT_CONFIGS } from '@/lib/sport-presets';
import type { RefundPolicy, VenueCourt, VenueSlot, VenueSlotStatus } from '@/lib/types/db';
import { SlotEditSheet } from './slot-edit-sheet';

const SPORT_EMOJI = Object.fromEntries(SPORT_CONFIGS.map((c) => [c.sport, c.emoji]));

const HOUR_PX = 64;
const ROW_PX = 56;
const HOURS = Array.from({ length: 17 }, (_, i) => i + 6); // 6 AM to 10 PM

interface BookingShape {
  id: string;
  slot_id: string;
  status: string;
  party_size: number;
  captain: { display_name: string | null; avatar_url: string | null } | null;
}

export function CourtCalendar({
  venue,
  date,
  courts,
  slots,
  bookings,
}: {
  venue: {
    id: string;
    name: string;
    currency: string;
    sport: string;
    timezone: string;
    default_refund_policy: RefundPolicy;
  };
  date: string; // venue-local "YYYY-MM-DD"
  courts: VenueCourt[];
  slots: VenueSlot[];
  bookings: BookingShape[];
}) {
  const router = useRouter();
  const tz = venue.timezone;
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const [editing, setEditing] = useState<{ kind: 'new'; courtId: string; hour: number } | { kind: 'edit'; slotId: string } | null>(null);

  const tree = useMemo(() => buildCourtTree(courts), [courts]);
  const slotsByCourt = useMemo(() => {
    const m = new Map<string, VenueSlot[]>();
    for (const s of slots) {
      const arr = m.get(s.court_id) ?? [];
      arr.push(s);
      m.set(s.court_id, arr);
    }
    return m;
  }, [slots]);

  // A shared (golf) slot can hold several bookings, so map slot → list.
  const bookingsBySlot = useMemo(() => {
    const m = new Map<string, BookingShape[]>();
    for (const b of bookings) {
      const arr = m.get(b.slot_id) ?? [];
      arr.push(b);
      m.set(b.slot_id, arr);
    }
    return m;
  }, [bookings]);

  function shiftDay(delta: number) {
    router.push(`/calendar?d=${addDaysYmd(date, delta)}`);
  }

  function toggleCollapse(id: string) {
    setCollapsed((c) => {
      const next = new Set(c);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  // Flatten the tree, skipping descendants of collapsed nodes.
  const flatRows = useMemo(() => flattenTree(tree, collapsed), [tree, collapsed]);

  return (
    <div className="flex h-full flex-col">
      <header className="flex items-center justify-between border-b border-line/50 px-8 py-4">
        <div className="flex items-center gap-4">
          <h1 className="text-xl font-medium tracking-tight">{venue.name}</h1>
          <span className="text-sm text-ink-dim">·</span>
          <p className="text-sm text-ink-dim capitalize">{venue.sport}</p>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="ghost" size="icon" onClick={() => shiftDay(-1)}>
            <ChevronLeft className="h-4 w-4" />
          </Button>
          <span className="min-w-[140px] text-center text-sm font-medium">{formatYmd(date)}</span>
          <Button variant="ghost" size="icon" onClick={() => shiftDay(1)}>
            <ChevronRight className="h-4 w-4" />
          </Button>
          <Button variant="ghost" size="sm" onClick={() => router.push(`/calendar?d=${ymdInTz(new Date(), tz)}`)}>
            Today
          </Button>
        </div>
      </header>

      <div className="flex-1 overflow-auto">
        <div className="min-w-[960px]">
          {/* Hour ruler */}
          <div className="sticky top-0 z-10 grid grid-cols-[200px_1fr] border-b border-line/50 bg-bg-0">
            <div className="px-3 py-2 text-[11px] uppercase tracking-wide text-ink-mute">
              Court
            </div>
            <div className="relative h-9">
              {HOURS.map((h, i) => (
                <div
                  key={h}
                  className="absolute top-0 flex h-full items-center border-l border-line/40 px-2 text-[11px] text-ink-mute font-mono"
                  style={{ left: i * HOUR_PX, width: HOUR_PX }}
                >
                  {h}:00
                </div>
              ))}
            </div>
          </div>

          {/* Court rows */}
          {flatRows.map((row) => {
            const isCollapsed = collapsed.has(row.node.id);
            const courtSlots = slotsByCourt.get(row.node.id) ?? [];

            return (
              <div
                key={row.node.id}
                className="grid grid-cols-[200px_1fr] border-b border-line/40"
                style={{ height: ROW_PX }}
              >
                <button
                  onClick={() => row.hasChildren && toggleCollapse(row.node.id)}
                  className={cn(
                    'flex items-center justify-between gap-2 border-r border-line/40 px-3 text-left text-[13px] transition-colors',
                    row.hasChildren && 'hover:bg-bg-1',
                  )}
                  style={{ paddingLeft: 12 + row.depth * 14 }}
                >
                  <div className="flex items-center gap-1.5 min-w-0 flex-1">
                    {row.hasChildren && (
                      <ChevronDown
                        className={cn(
                          'h-3 w-3 text-ink-mute transition-transform',
                          isCollapsed && '-rotate-90',
                        )}
                      />
                    )}
                    {row.depth === 0 && SPORT_EMOJI[row.node.sport] && (
                      <span className="leading-none" title={row.node.sport}>
                        {SPORT_EMOJI[row.node.sport]}
                      </span>
                    )}
                    <span className="truncate text-ink">{row.node.name}</span>
                  </div>
                  {/* When collapsed, show inline mini-grid of children's status — the screenshot-worthy detail */}
                  {row.hasChildren && isCollapsed && (
                    <MiniGrid
                      childIds={row.descendantIds}
                      slotsByCourt={slotsByCourt}
                    />
                  )}
                  {row.node.capacity && !isCollapsed && (
                    <Badge tone="neutral" className="font-mono text-[10px]">
                      {row.node.capacity}
                    </Badge>
                  )}
                </button>

                <div
                  className="relative"
                  onClick={(e) => {
                    // Click on empty cell creates a new slot at that hour.
                    const rect = (e.currentTarget as HTMLDivElement).getBoundingClientRect();
                    const x = e.clientX - rect.left;
                    const hourIdx = Math.floor(x / HOUR_PX);
                    const hour = HOURS[hourIdx];
                    if (hour !== undefined) {
                      setEditing({ kind: 'new', courtId: row.node.id, hour });
                    }
                  }}
                >
                  {/* Hour gridlines */}
                  {HOURS.map((_, i) => (
                    <div
                      key={i}
                      className="absolute top-0 h-full border-l border-line/30"
                      style={{ left: i * HOUR_PX }}
                    />
                  ))}

                  {/* Slot blocks */}
                  {courtSlots.map((s) => (
                    <SlotBlock
                      key={s.id}
                      slot={s}
                      bookings={bookingsBySlot.get(s.id) ?? []}
                      currency={venue.currency}
                      tz={tz}
                      onClick={(e) => {
                        e.stopPropagation();
                        setEditing({ kind: 'edit', slotId: s.id });
                      }}
                    />
                  ))}
                </div>
              </div>
            );
          })}

          {flatRows.length === 0 && <EmptyCalendar />}
        </div>
      </div>

      {/* Legend footer */}
      <footer className="flex items-center gap-4 border-t border-line/50 px-8 py-2.5 text-[11px] text-ink-mute">
        <Legend dot="bg-brand" label="Booked" />
        <Legend dot="bg-warn" label="Held" />
        <Legend dot="bg-bg-2 border border-dashed border-line" label="Available" />
        <Legend dot="bg-line" label="Closed" />
        <span className="ml-auto">Click an empty hour to add a slot</span>
      </footer>

      {editing && (
        <SlotEditSheet
          venueId={venue.id}
          editing={editing}
          courts={courts}
          existingSlot={
            editing.kind === 'edit' ? slots.find((s) => s.id === editing.slotId) ?? null : null
          }
          existingBookings={
            editing.kind === 'edit' ? bookingsBySlot.get(editing.slotId) ?? [] : []
          }
          currency={venue.currency}
          dayYmd={date}
          timezone={tz}
          venueDefaultPolicy={venue.default_refund_policy}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setEditing(null);
            router.refresh();
          }}
        />
      )}
    </div>
  );
}

function SlotBlock({
  slot,
  bookings,
  currency,
  tz,
  onClick,
}: {
  slot: VenueSlot;
  bookings: BookingShape[];
  currency: string;
  tz: string;
  onClick: (e: React.MouseEvent) => void;
}) {
  const start = new Date(slot.starts_at);
  const end = new Date(slot.ends_at);
  const baseHour = HOURS[0];
  const left = (hourInTz(start, tz) - baseHour) * HOUR_PX;
  const width = ((end.getTime() - start.getTime()) / 3_600_000) * HOUR_PX;
  const startLabel = formatTimeInTz(start, tz);

  const shared = slot.booking_mode === 'shared';
  const perPlayer = slot.pricing_mode === 'per_player';
  const priceCents = perPlayer ? slot.price_per_player_cents ?? slot.price_cents : slot.price_cents;
  const booked = bookings.reduce((s, b) => s + (b.party_size ?? 1), 0);

  // A shared tee time fills up gradually; show it as booked once anyone is on it.
  const effectiveStatus =
    shared && booked > 0 && booked >= (slot.max_players ?? Infinity)
      ? 'booked'
      : shared && booked > 0
        ? 'held'
        : slot.status;
  const colors = colorForStatus(effectiveStatus as VenueSlotStatus);

  const label = shared
    ? `${booked}/${slot.max_players ?? '?'}`
    : bookings[0]?.captain?.display_name ?? slot.status;

  // Tee times are short and pack tightly; let them shrink more than court slots.
  const minWidth = shared ? 18 : 28;

  return (
    <button
      onClick={onClick}
      className={cn(
        'absolute top-1 bottom-1 rounded-md border px-1.5 py-1 text-left text-[11px] transition-colors',
        colors.bg,
        colors.border,
        colors.text,
      )}
      style={{ left, width: Math.max(width - 4, minWidth) }}
      title={`${startLabel} · ${
        shared ? `${booked}/${slot.max_players} players` : slot.status
      } · ${formatMoney(priceCents, currency)}${perPlayer ? '/player' : ''}`}
    >
      <div className="flex items-center justify-between gap-1">
        <span className="truncate font-medium">{label}</span>
        {!shared && (
          <span className="font-mono tnum text-[10px] opacity-90">
            {formatMoney(priceCents, currency)}
          </span>
        )}
      </div>
      <div className="text-[10px] opacity-80 font-mono">{startLabel}</div>
    </button>
  );
}

function MiniGrid({
  childIds,
  slotsByCourt,
}: {
  childIds: string[];
  slotsByCourt: Map<string, VenueSlot[]>;
}) {
  // Compact 2x2-ish dots showing aggregate status of descendants. Not precise
  // about time, just a visual cue that the parent is busy.
  const children = childIds.slice(0, 4);
  const cellsToShow = 4;
  return (
    <div className="grid grid-cols-2 gap-0.5" aria-hidden>
      {Array.from({ length: cellsToShow }).map((_, i) => {
        const childId = children[i];
        const someSlot = childId ? slotsByCourt.get(childId)?.[0] : undefined;
        const cls = someSlot ? colorForStatus(someSlot.status).dot : 'bg-bg-2';
        return <span key={i} className={cn('h-2 w-2 rounded-[2px]', cls)} />;
      })}
    </div>
  );
}

function colorForStatus(status: VenueSlotStatus) {
  switch (status) {
    case 'booked':
      return { bg: 'bg-brand text-bg-0', border: 'border-brand', text: 'text-bg-0', dot: 'bg-brand' };
    case 'held':
      return { bg: 'bg-warn/20', border: 'border-warn/60', text: 'text-warn', dot: 'bg-warn' };
    case 'available':
      return {
        bg: 'bg-bg-2/40',
        border: 'border-dashed border-line/80',
        text: 'text-ink-dim',
        dot: 'bg-bg-2 border border-line',
      };
    case 'closed':
    case 'cancelled':
      return { bg: 'bg-bg-2/30', border: 'border-line', text: 'text-ink-mute line-through', dot: 'bg-line' };
  }
}

function Legend({ dot, label }: { dot: string; label: string }) {
  return (
    <span className="inline-flex items-center gap-1.5">
      <span className={`h-2 w-2 rounded-sm ${dot}`} />
      {label}
    </span>
  );
}

function EmptyCalendar() {
  return (
    <div className="grid place-items-center py-24 text-center">
      <p className="text-sm text-ink-dim">No courts yet.</p>
      <Button asChild variant="ghost" size="sm" className="mt-3">
        <Link href="/onboarding/courts">Add your courts</Link>
      </Button>
    </div>
  );
}

interface CourtTreeNode extends VenueCourt {
  children: CourtTreeNode[];
}

function buildCourtTree(courts: VenueCourt[]): CourtTreeNode[] {
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
  return roots;
}

interface FlatRow {
  node: CourtTreeNode;
  depth: number;
  hasChildren: boolean;
  descendantIds: string[];
}

function flattenTree(roots: CourtTreeNode[], collapsed: Set<string>): FlatRow[] {
  const out: FlatRow[] = [];
  function walk(node: CourtTreeNode, depth: number) {
    const descendantIds = collectDescendantIds(node);
    out.push({
      node,
      depth,
      hasChildren: node.children.length > 0,
      descendantIds,
    });
    if (collapsed.has(node.id)) return;
    for (const c of node.children) walk(c, depth + 1);
  }
  for (const r of roots) walk(r, 0);
  return out;
}

function collectDescendantIds(node: CourtTreeNode): string[] {
  const out: string[] = [];
  for (const c of node.children) {
    out.push(c.id, ...collectDescendantIds(c));
  }
  return out;
}

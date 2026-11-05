'use client';

import { Plus } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { cn } from '@/lib/cn';
import { formatMoney } from '@/lib/format';
import { formatYmd } from '@/lib/tz';
import type { SpotState, TeeSheet, TeeSheetRow, TeeTimeStatus } from '@/lib/tee-sheet';

// Time | spots | parties | price per golfer | status
const COLS = 'grid-cols-[84px_112px_minmax(0,1fr)_200px_112px]';

const STATUS_TONE: Record<TeeTimeStatus, 'neutral' | 'accent' | 'brand'> = {
  open: 'neutral',
  partly_booked: 'accent',
  full: 'brand',
  closed: 'neutral',
};

// Shared with the calendar legend.
export const SPOT_CLASS: Record<SpotState, string> = {
  paid: 'bg-brand',
  pending: 'bg-warn',
  open: 'border border-ink-mute/70 bg-transparent',
};

export function TeeSheetList({
  sheets,
  date,
  currency,
  onEdit,
  onAdd,
}: {
  sheets: TeeSheet[];
  date: string;
  currency: string;
  onEdit: (slotId: string) => void;
  onAdd: (courtId: string, hour: number) => void;
}) {
  return (
    <div className="space-y-6 px-8 py-6">
      {sheets.map((sheet) => (
        <CourseSheet
          key={sheet.court.id}
          sheet={sheet}
          date={date}
          currency={currency}
          onEdit={onEdit}
          onAdd={(hour) => onAdd(sheet.court.id, hour)}
        />
      ))}
    </div>
  );
}

function CourseSheet({
  sheet,
  date,
  currency,
  onEdit,
  onAdd,
}: {
  sheet: TeeSheet;
  date: string;
  currency: string;
  onEdit: (slotId: string) => void;
  onAdd: (hour: number) => void;
}) {
  const { court, rows, summary } = sheet;
  const last = rows.at(-1);
  // New tee times start after the last one of the day, or at 6 AM.
  const nextHour = last ? Math.min(last.hour + 1, 22) : 6;

  return (
    <section className="card-base overflow-hidden">
      <header className="flex flex-wrap items-center justify-between gap-3 border-b border-line/50 px-5 py-3">
        <div className="flex min-w-0 items-center gap-2">
          <span className="leading-none" aria-hidden>
            ⛳
          </span>
          <h2 className="truncate text-sm font-medium text-ink">{court.name}</h2>
          <span className="text-[11px] text-ink-mute">Tee sheet</span>
        </div>
        <div className="flex items-center gap-4">
          {rows.length > 0 && (
            <dl className="flex items-center gap-4 text-[11px] text-ink-mute">
              <Stat label="tee times" value={summary.teeTimes} />
              <Stat label="with spots" value={summary.bookable} />
              <Stat label="golfers" value={`${summary.golfers}/${summary.spots}`} />
            </dl>
          )}
          <Button variant="outline" size="sm" onClick={() => onAdd(nextHour)}>
            <Plus className="h-3.5 w-3.5" />
            Add tee times
          </Button>
        </div>
      </header>

      {rows.length === 0 ? (
        <div className="px-5 py-10 text-center">
          <p className="text-sm text-ink-dim">No tee times on {formatYmd(date)}.</p>
          <p className="mt-1 text-xs text-ink-mute">
            Generate them here, or set weekly hours in Settings, Schedule.
          </p>
        </div>
      ) : (
        <div className="overflow-x-auto">
          <div className="min-w-[760px]">
            <div
              className={cn(
                'grid items-center gap-4 border-b border-line/40 bg-bg-0/40 px-5 py-2 text-[11px] uppercase tracking-wide text-ink-mute',
                COLS,
              )}
            >
              <span>Time</span>
              <span>Spots</span>
              <span>Players</span>
              <span className="text-right">Per golfer</span>
              <span className="text-right">Status</span>
            </div>
            <ol>
              {rows.map((row, i) => (
                <li key={row.slotId}>
                  <TeeTimeRow row={row} first={i === 0} currency={currency} onClick={() => onEdit(row.slotId)} />
                </li>
              ))}
            </ol>
          </div>
        </div>
      )}
    </section>
  );
}

function Stat({ label, value }: { label: string; value: number | string }) {
  return (
    <div className="flex items-baseline gap-1">
      <dd className="font-mono tnum text-[12px] text-ink">{value}</dd>
      <dt>{label}</dt>
    </div>
  );
}

function TeeTimeRow({
  row,
  first,
  currency,
  onClick,
}: {
  row: TeeSheetRow;
  first: boolean;
  currency: string;
  onClick: () => void;
}) {
  const closed = row.status === 'closed';
  const label = `${row.time}, ${row.statusLabel}, ${row.booked} of ${row.capacity} spots booked`;

  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={`Edit tee time ${label}`}
      className={cn(
        'grid w-full items-center gap-4 px-5 py-2 text-left text-[13px] transition-colors hover:bg-bg-2/50 focus-visible:bg-bg-2/60 focus-visible:outline-none',
        COLS,
        !first && (row.newHour ? 'border-t border-line/70' : 'border-t border-line/25'),
        closed && 'opacity-60',
      )}
    >
      <span className={cn('font-mono tnum', row.newHour ? 'text-ink' : 'text-ink-dim', closed && 'line-through')}>
        {row.time}
      </span>

      <span className="flex items-center gap-2">
        <span className="flex gap-1" aria-hidden>
          {row.spots.map((s, i) => (
            <span key={i} className={cn('h-2.5 w-2.5 rounded-[3px]', SPOT_CLASS[s])} />
          ))}
        </span>
        <span className="font-mono tnum text-[11px] text-ink-mute">
          {row.booked}/{row.capacity}
        </span>
      </span>

      <span className="flex min-w-0 flex-wrap gap-1.5">
        {row.parties.length === 0 ? (
          <span className="text-xs text-ink-mute">{closed ? 'Closed' : 'No bookings'}</span>
        ) : (
          row.parties.map((p) => (
            <span
              key={p.id}
              title={p.pending ? 'Awaiting payment' : 'Paid'}
              className={cn(
                'inline-flex max-w-full items-center gap-1.5 rounded-md border px-2 py-0.5 text-[12px]',
                p.pending ? 'border-warn/40 bg-warn/10' : 'border-line/60 bg-bg-2/60',
              )}
            >
              <span className="truncate text-ink">{p.name}</span>
              <span className="text-ink-mute">·</span>
              <span className="whitespace-nowrap text-ink-dim">{p.partyLabel}</span>
              <span className="text-ink-mute">·</span>
              <span className={cn('whitespace-nowrap font-mono tnum', p.holes === 9 ? 'text-accent' : 'text-ink-dim')}>
                {p.holesLabel}
              </span>
            </span>
          ))
        )}
      </span>

      <span className="flex items-baseline justify-end gap-3 whitespace-nowrap font-mono tnum text-[12px]">
        <span className="text-ink" title="18 holes, per golfer">
          <span className="mr-1 text-[10px] text-ink-mute">18</span>
          {formatMoney(row.price18Cents, currency)}
        </span>
        <span
          className={row.price9Cents === null ? 'text-ink-mute' : 'text-ink-dim'}
          title={row.price9Cents === null ? '9 hole rounds are not offered' : '9 holes, per golfer'}
        >
          <span className="mr-1 text-[10px] text-ink-mute">9</span>
          {row.price9Cents === null ? 'n/a' : formatMoney(row.price9Cents, currency)}
        </span>
      </span>

      <span className="flex justify-end">
        <Badge tone={STATUS_TONE[row.status]}>{row.statusLabel}</Badge>
      </span>
    </button>
  );
}

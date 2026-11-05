'use client';

import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { CalendarClock } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { createClient } from '@/lib/supabase/client';
import { SPORT_CONFIGS } from '@/lib/sport-presets';
import { addDaysYmd, ymdInTz } from '@/lib/tz';
import {
  DAYS,
  GENERATE_MAX_DAYS,
  GENERATE_MAX_ROWS,
  buildTemplatePayload,
  courtGroups,
  groupLabel,
  offersNineHoles,
  seedWeek,
  type DaySchedule,
  type ScheduleCourt,
  type ScheduleTemplate,
  type Week,
} from '@/lib/schedule';
import type { Json, VenueSport } from '@/lib/types/db';

const WEEKDAYS = [1, 2, 3, 4, 5];
const WEEKEND = [6, 0];

const SPORT_META = Object.fromEntries(SPORT_CONFIGS.map((c) => [c.sport, c]));
const sportLabel = (s: VenueSport) => SPORT_META[s]?.label ?? s;

export function ScheduleEditor({
  venueId,
  currency,
  timezone,
  sports,
  courts,
  templates,
}: {
  venueId: string;
  currency: string;
  timezone: string;
  sports: VenueSport[];
  courts: ScheduleCourt[];
  templates: ScheduleTemplate[];
}) {
  const router = useRouter();
  const groups = useMemo(() => courtGroups(courts, sports), [courts, sports]);
  const [activeKey, setActiveKey] = useState<string | null>(groups[0]?.key ?? null);
  const [weeks, setWeeks] = useState<Record<string, Week>>(() =>
    Object.fromEntries(groups.map((g) => [g.key, seedWeek(g, templates)])),
  );
  const group = groups.find((g) => g.key === activeKey) ?? groups[0] ?? null;
  const days = group ? weeks[group.key] : null;
  const shared = group?.bookingMode === 'shared';
  // A golf tee sheet prices 18 holes and, optionally, 9 holes per golfer (C14).
  const nine = group ? offersNineHoles(group) : false;
  const label = group ? groupLabel(group, groups, sportLabel) : '';

  // Quick-fill row.
  const [fill, setFill] = useState({ open: '09:00', close: '20:00', slotMinutes: 60, price: '1500', price9: '' });
  const [saving, setSaving] = useState(false);
  const [savedMsg, setSavedMsg] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Generate controls, in venue local dates.
  const today = useMemo(() => ymdInTz(new Date(), timezone), [timezone]);
  const maxThrough = addDaysYmd(today, GENERATE_MAX_DAYS);
  const [through, setThrough] = useState(() => addDaysYmd(today, 30));
  const [generating, setGenerating] = useState(false);
  const [genMsg, setGenMsg] = useState<string | null>(null);
  const [genError, setGenError] = useState<string | null>(null);

  function patchWeek(next: (w: Week) => Week) {
    if (!group) return;
    setWeeks((m) => ({ ...m, [group.key]: next(m[group.key]) }));
    setSavedMsg(null);
  }

  function patchDay(dow: number, patch: Partial<DaySchedule>) {
    patchWeek((w) => ({ ...w, [dow]: { ...w[dow], ...patch } }));
  }

  function applyFill(dows: number[]) {
    patchWeek((w) => {
      const next = { ...w };
      for (const dow of dows) next[dow] = { enabled: true, ...fill };
      return next;
    });
  }

  async function save() {
    if (!group || !days) return;
    setError(null);
    setSavedMsg(null);
    // Validate the whole week before anything is sent.
    const payload = buildTemplatePayload(days, { ninePrice: nine });
    if (!payload.ok) {
      setError(payload.error);
      return;
    }
    setSaving(true);
    const supabase = createClient();
    const { error: e } = await supabase.rpc('replace_venue_slot_templates', {
      _venue_id: venueId,
      _sport: group.sport,
      _booking_mode: group.bookingMode,
      _templates: payload.templates as unknown as Json,
    });
    setSaving(false);
    if (e) {
      setError(e.message);
      return;
    }
    const n = group.courts.length;
    setSavedMsg(
      payload.templates.length === 0
        ? `Cleared ${label} hours.`
        : `Saved ${label} hours across ${n} court${n === 1 ? '' : 's'}.`,
    );
    router.refresh();
  }

  async function generate() {
    setGenMsg(null);
    setGenError(null);
    if (!through || through < today || through > maxThrough) {
      setGenError(`Pick a date from ${today} to ${maxThrough}.`);
      return;
    }
    setGenerating(true);
    const supabase = createClient();
    const { data, error: e } = await supabase.rpc('generate_venue_slots', {
      _venue_id: venueId,
      _through: through,
    });
    setGenerating(false);
    if (e) {
      setGenError(e.message);
      return;
    }
    setGenMsg(`Generated ${data ?? 0} new slot${data === 1 ? '' : 's'} through ${through}.`);
    router.refresh();
  }

  if (!group || !days) {
    return (
      <div className="card-base p-5 text-sm text-ink-dim">
        No active courts yet. Add courts in Settings → Courts, then set their weekly hours here.
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Court group tabs */}
      {groups.length > 1 && (
        <div className="flex flex-wrap gap-2">
          {groups.map((g) => {
            const cfg = SPORT_META[g.sport];
            return (
              <button
                type="button"
                key={g.key}
                onClick={() => {
                  setActiveKey(g.key);
                  setError(null);
                  setSavedMsg(null);
                }}
                className={`inline-flex items-center gap-1.5 rounded-md border px-3 py-2 text-sm transition-colors ${
                  g.key === group.key
                    ? 'border-brand bg-brand/10 text-brand'
                    : 'border-line/70 bg-bg-1 text-ink-dim hover:border-line'
                }`}
              >
                <span>{cfg?.emoji}</span>
                {groupLabel(g, groups, sportLabel)}
              </button>
            );
          })}
        </div>
      )}

      {/* Quick fill */}
      <div className="card-base p-4">
        <p className="mb-3 text-xs font-medium uppercase tracking-wide text-ink-mute">Quick fill</p>
        <div className="flex flex-wrap items-end gap-3">
          <Field label="Open">
            <Input type="time" step={300} value={fill.open} onChange={(e) => setFill((f) => ({ ...f, open: e.target.value }))} className="w-28" />
          </Field>
          <Field label="Close">
            <Input type="time" step={300} value={fill.close} onChange={(e) => setFill((f) => ({ ...f, close: e.target.value }))} className="w-28" />
          </Field>
          <Field label={shared ? 'Tee interval (min)' : 'Slot length (min)'}>
            <Input type="number" min={5} max={1440} value={fill.slotMinutes} onChange={(e) => setFill((f) => ({ ...f, slotMinutes: Number(e.target.value) }))} className="w-24" />
          </Field>
          <Field label={nine ? '18 holes / golfer' : shared ? 'Price / player' : 'Price'}>
            <Input inputMode="numeric" value={fill.price} onChange={(e) => setFill((f) => ({ ...f, price: e.target.value.replace(/[^0-9]/g, '') }))} className="w-24" />
          </Field>
          {nine && (
            <Field label="9 holes / golfer">
              <Input inputMode="numeric" placeholder="Not offered" value={fill.price9} onChange={(e) => setFill((f) => ({ ...f, price9: e.target.value.replace(/[^0-9]/g, '') }))} className="w-28" />
            </Field>
          )}
          <div className="flex gap-1.5">
            <Button type="button" variant="outline" size="sm" onClick={() => applyFill(DAYS.map((d) => d.dow))}>All days</Button>
            <Button type="button" variant="outline" size="sm" onClick={() => applyFill(WEEKDAYS)}>Weekdays</Button>
            <Button type="button" variant="outline" size="sm" onClick={() => applyFill(WEEKEND)}>Weekend</Button>
          </div>
        </div>
      </div>

      {/* Per-day grid */}
      <div className="card-base p-5">
        <div className="space-y-2">
          {DAYS.map(({ dow, label: dayLabel }) => {
            const ds = days[dow];
            return (
              <div key={dow} className="flex flex-wrap items-center gap-3">
                <label className="flex w-24 items-center gap-2 text-sm">
                  <input type="checkbox" checked={ds.enabled} onChange={(e) => patchDay(dow, { enabled: e.target.checked })} />
                  <span className={ds.enabled ? 'text-ink' : 'text-ink-mute'}>{dayLabel}</span>
                </label>
                {ds.enabled ? (
                  <>
                    <Input type="time" step={300} value={ds.open} onChange={(e) => patchDay(dow, { open: e.target.value })} className="h-8 w-28" />
                    <span className="text-ink-mute">→</span>
                    <Input type="time" step={300} value={ds.close} onChange={(e) => patchDay(dow, { close: e.target.value })} className="h-8 w-28" />
                    <Input type="number" min={5} max={1440} value={ds.slotMinutes} onChange={(e) => patchDay(dow, { slotMinutes: Number(e.target.value) })} className={nine ? 'h-8 w-16' : 'h-8 w-20'} title="minutes" />
                    <div className="flex items-center gap-1">
                      <span className="text-ink-mute font-mono">₱</span>
                      <Input inputMode="numeric" value={ds.price} onChange={(e) => patchDay(dow, { price: e.target.value.replace(/[^0-9]/g, '') })} className={nine ? 'h-8 w-20' : 'h-8 w-24'} aria-label={nine ? `${dayLabel} 18 hole price per golfer` : `${dayLabel} price`} />
                      {shared && <span className="text-[11px] text-ink-mute">{nine ? '18 holes' : '/player'}</span>}
                    </div>
                    {nine && (
                      <div className="flex items-center gap-1">
                        <span className="text-ink-mute font-mono">₱</span>
                        <Input inputMode="numeric" placeholder="Not offered" value={ds.price9} onChange={(e) => patchDay(dow, { price9: e.target.value.replace(/[^0-9]/g, '') })} className="h-8 w-24 placeholder:text-[12px]" aria-label={`${dayLabel} 9 hole price per golfer`} />
                        <span className="text-[11px] text-ink-mute">9 holes</span>
                      </div>
                    )}
                  </>
                ) : (
                  <span className="text-xs text-ink-mute">Closed</span>
                )}
              </div>
            );
          })}
        </div>

        <p className="mt-4 text-[11px] text-ink-mute">
          Applies to {group.courts.map((c) => c.name).join(', ')} ({group.courts.length} active court
          {group.courts.length === 1 ? '' : 's'}).{' '}
          {nine
            ? 'Slot length is the tee time interval. Prices are per golfer; leave the 9 hole price blank to offer 18 holes only. Each tee time takes up to 4 golfers.'
            : shared
              ? 'Slot length is the tee time interval; price is per player.'
              : ''}
        </p>

        {error && <p className="mt-3 text-xs text-danger">{error}</p>}
        {savedMsg && <p className="mt-3 text-xs text-brand">{savedMsg}</p>}

        <div className="mt-4 flex justify-end">
          <Button onClick={save} disabled={saving}>
            {saving ? 'Saving…' : `Save ${label} hours`}
          </Button>
        </div>
      </div>

      {/* Generate */}
      <div className="card-base p-5">
        <div className="flex items-center gap-2">
          <CalendarClock className="h-4 w-4 text-brand" />
          <p className="text-sm font-medium text-ink">Generate bookable slots</p>
        </div>
        <p className="mt-1 text-xs text-ink-dim">
          Materializes slots from every group&apos;s saved hours, from now through the chosen date
          (venue time). Skips anything that would overlap an existing slot or fall inside a closure,
          so it is safe to run repeatedly.
        </p>
        <div className="mt-3 flex flex-wrap items-end gap-3">
          <Field label="Through date">
            <Input
              type="date"
              min={today}
              max={maxThrough}
              value={through}
              onChange={(e) => setThrough(e.target.value)}
              className="w-44"
            />
          </Field>
          <Button onClick={generate} disabled={generating}>
            {generating ? 'Generating…' : 'Generate slots'}
          </Button>
          {genMsg && <Badge tone="brand">{genMsg}</Badge>}
        </div>
        {genError && <p className="mt-2 text-xs text-danger">{genError}</p>}
        <p className="mt-2 text-[11px] text-ink-mute">
          Currency: {currency}. Up to {GENERATE_MAX_DAYS} days ahead and{' '}
          {GENERATE_MAX_ROWS.toLocaleString('en-US')} slots per run.
        </p>
      </div>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1">
      <Label className="text-[11px] text-ink-mute">{label}</Label>
      {children}
    </div>
  );
}

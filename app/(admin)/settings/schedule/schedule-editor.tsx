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
import { addDaysYmd } from '@/lib/tz';
import type { VenueSport } from '@/lib/types/db';

interface Court {
  id: string;
  sport: VenueSport;
  name: string;
  active: boolean;
}
interface Template {
  court_id: string;
  day_of_week: number;
  start_time: string;
  end_time: string;
  slot_minutes: number;
  price_cents: number;
  active: boolean;
}

interface DaySchedule {
  enabled: boolean;
  open: string; // HH:MM
  close: string;
  slotMinutes: number;
  price: string; // major units
}

// Display order Mon → Sun, stored as JS day_of_week (0 = Sun).
const DAYS = [
  { dow: 1, label: 'Mon' },
  { dow: 2, label: 'Tue' },
  { dow: 3, label: 'Wed' },
  { dow: 4, label: 'Thu' },
  { dow: 5, label: 'Fri' },
  { dow: 6, label: 'Sat' },
  { dow: 0, label: 'Sun' },
];
const WEEKDAYS = [1, 2, 3, 4, 5];
const WEEKEND = [6, 0];

const SPORT_META = Object.fromEntries(SPORT_CONFIGS.map((c) => [c.sport, c]));

function defaultDay(): DaySchedule {
  return { enabled: false, open: '09:00', close: '20:00', slotMinutes: 60, price: '1500' };
}

// Seed a sport's weekly schedule from its representative court's templates.
function seedSchedule(sport: VenueSport, courts: Court[], templates: Template[]): Record<number, DaySchedule> {
  const out: Record<number, DaySchedule> = {};
  for (const { dow } of DAYS) out[dow] = defaultDay();
  const repCourt = courts.find((c) => c.sport === sport);
  if (!repCourt) return out;
  for (const t of templates.filter((t) => t.court_id === repCourt.id && t.active)) {
    out[t.day_of_week] = {
      enabled: true,
      open: t.start_time.slice(0, 5),
      close: t.end_time.slice(0, 5),
      slotMinutes: t.slot_minutes,
      price: String(Math.round(t.price_cents / 100)),
    };
  }
  return out;
}

export function ScheduleEditor({
  venueId,
  currency,
  sports,
  courts,
  templates,
}: {
  venueId: string;
  currency: string;
  sports: VenueSport[];
  courts: Court[];
  templates: Template[];
}) {
  const router = useRouter();
  const [activeSport, setActiveSport] = useState<VenueSport>(sports[0]);
  const [schedules, setSchedules] = useState<Record<string, Record<number, DaySchedule>>>(() =>
    Object.fromEntries(sports.map((s) => [s, seedSchedule(s, courts, templates)])),
  );
  // Quick-fill row.
  const [fill, setFill] = useState({ open: '09:00', close: '20:00', slotMinutes: 60, price: '1500' });
  const [savingSport, setSavingSport] = useState(false);
  const [savedMsg, setSavedMsg] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Generate controls.
  const [through, setThrough] = useState(() => addDaysYmd(new Date().toISOString().slice(0, 10), 30));
  const [generating, setGenerating] = useState(false);
  const [genMsg, setGenMsg] = useState<string | null>(null);

  const sportCourts = useMemo(() => courts.filter((c) => c.sport === activeSport), [courts, activeSport]);
  const days = schedules[activeSport];
  const isGolf = activeSport === 'golf';

  function patchDay(dow: number, patch: Partial<DaySchedule>) {
    setSchedules((m) => ({
      ...m,
      [activeSport]: { ...m[activeSport], [dow]: { ...m[activeSport][dow], ...patch } },
    }));
    setSavedMsg(null);
  }

  function applyFill(dows: number[]) {
    setSchedules((m) => {
      const next = { ...m[activeSport] };
      for (const dow of dows) {
        next[dow] = {
          enabled: true,
          open: fill.open,
          close: fill.close,
          slotMinutes: fill.slotMinutes,
          price: fill.price,
        };
      }
      return { ...m, [activeSport]: next };
    });
    setSavedMsg(null);
  }

  async function saveSport() {
    setError(null);
    setSavedMsg(null);
    const courtIds = sportCourts.map((c) => c.id);
    if (courtIds.length === 0) {
      setError('No active courts for this sport — add courts first.');
      return;
    }
    setSavingSport(true);
    const supabase = createClient();

    // Replace this sport's templates wholesale.
    const { error: delErr } = await supabase
      .from('venue_slot_templates')
      .delete()
      .in('court_id', courtIds);
    if (delErr) {
      setError(delErr.message);
      setSavingSport(false);
      return;
    }

    const rows: Record<string, unknown>[] = [];
    for (const { dow } of DAYS) {
      const ds = days[dow];
      if (!ds.enabled) continue;
      if (ds.close <= ds.open) {
        setError(`${labelFor(dow)}: closing time must be after opening time.`);
        setSavingSport(false);
        return;
      }
      const price_cents = Math.max(0, Math.round((Number(ds.price) || 0) * 100));
      for (const courtId of courtIds) {
        rows.push({
          venue_id: venueId,
          court_id: courtId,
          day_of_week: dow,
          start_time: `${ds.open}:00`,
          end_time: `${ds.close}:00`,
          slot_minutes: ds.slotMinutes,
          price_cents,
          active: true,
        });
      }
    }

    if (rows.length > 0) {
      const { error: insErr } = await supabase.from('venue_slot_templates').insert(rows);
      if (insErr) {
        setError(insErr.message);
        setSavingSport(false);
        return;
      }
    }
    setSavingSport(false);
    setSavedMsg(
      `Saved ${SPORT_META[activeSport]?.label ?? activeSport} hours across ${courtIds.length} court${courtIds.length === 1 ? '' : 's'}.`,
    );
  }

  async function generate() {
    setGenMsg(null);
    setError(null);
    setGenerating(true);
    const supabase = createClient();
    const { data, error: e } = await supabase.rpc('generate_venue_slots', {
      _venue_id: venueId,
      _through: through,
    });
    setGenerating(false);
    if (e) {
      setError(e.message);
      return;
    }
    setGenMsg(`Generated ${data ?? 0} new slot${data === 1 ? '' : 's'} through ${through}.`);
    router.refresh();
  }

  return (
    <div className="space-y-6">
      {/* Sport tabs */}
      {sports.length > 1 && (
        <div className="flex flex-wrap gap-2">
          {sports.map((s) => {
            const cfg = SPORT_META[s];
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
                <span>{cfg?.emoji}</span>
                {cfg?.label ?? s}
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
          <Field label={isGolf ? 'Tee interval (min)' : 'Slot length (min)'}>
            <Input type="number" min={5} max={1440} value={fill.slotMinutes} onChange={(e) => setFill((f) => ({ ...f, slotMinutes: Math.max(5, Number(e.target.value) || 60) }))} className="w-24" />
          </Field>
          <Field label={isGolf ? 'Price / golfer' : 'Price'}>
            <Input inputMode="numeric" value={fill.price} onChange={(e) => setFill((f) => ({ ...f, price: e.target.value.replace(/[^0-9]/g, '') }))} className="w-24" />
          </Field>
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
          {DAYS.map(({ dow, label }) => {
            const ds = days[dow];
            return (
              <div key={dow} className="flex flex-wrap items-center gap-3">
                <label className="flex w-24 items-center gap-2 text-sm">
                  <input type="checkbox" checked={ds.enabled} onChange={(e) => patchDay(dow, { enabled: e.target.checked })} />
                  <span className={ds.enabled ? 'text-ink' : 'text-ink-mute'}>{label}</span>
                </label>
                {ds.enabled ? (
                  <>
                    <Input type="time" step={300} value={ds.open} onChange={(e) => patchDay(dow, { open: e.target.value })} className="h-8 w-28" />
                    <span className="text-ink-mute">→</span>
                    <Input type="time" step={300} value={ds.close} onChange={(e) => patchDay(dow, { close: e.target.value })} className="h-8 w-28" />
                    <Input type="number" min={5} max={1440} value={ds.slotMinutes} onChange={(e) => patchDay(dow, { slotMinutes: Math.max(5, Number(e.target.value) || 60) })} className="h-8 w-20" title="minutes" />
                    <div className="flex items-center gap-1">
                      <span className="text-ink-mute font-mono">₱</span>
                      <Input inputMode="numeric" value={ds.price} onChange={(e) => patchDay(dow, { price: e.target.value.replace(/[^0-9]/g, '') })} className="h-8 w-24" />
                      {isGolf && <span className="text-[11px] text-ink-mute">/golfer</span>}
                    </div>
                  </>
                ) : (
                  <span className="text-xs text-ink-mute">Closed</span>
                )}
              </div>
            );
          })}
        </div>

        <p className="mt-4 text-[11px] text-ink-mute">
          Applies to all {sportCourts.length} active {SPORT_META[activeSport]?.label ?? activeSport} court
          {sportCourts.length === 1 ? '' : 's'}. {isGolf ? 'Slot length is the tee-time interval; price is per golfer.' : ''}
        </p>

        {error && <p className="mt-3 text-xs text-danger">{error}</p>}
        {savedMsg && <p className="mt-3 text-xs text-brand">{savedMsg}</p>}

        <div className="mt-4 flex justify-end">
          <Button onClick={saveSport} disabled={savingSport}>
            {savingSport ? 'Saving…' : `Save ${SPORT_META[activeSport]?.label ?? activeSport} hours`}
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
          Materializes slots from every sport&apos;s saved hours, from today through the chosen date.
          Skips slots that already exist and any inside a closure — safe to run repeatedly.
        </p>
        <div className="mt-3 flex flex-wrap items-end gap-3">
          <Field label="Through date">
            <Input type="date" value={through} onChange={(e) => setThrough(e.target.value)} className="w-44" />
          </Field>
          <Button onClick={generate} disabled={generating}>
            {generating ? 'Generating…' : 'Generate slots'}
          </Button>
          {genMsg && <Badge tone="brand">{genMsg}</Badge>}
        </div>
        <p className="mt-2 text-[11px] text-ink-mute">
          Currency: {currency}. Tip: generate a month or two at a time.
        </p>
      </div>
    </div>
  );
}

function labelFor(dow: number): string {
  return DAYS.find((d) => d.dow === dow)?.label ?? String(dow);
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1">
      <Label className="text-[11px] text-ink-mute">{label}</Label>
      {children}
    </div>
  );
}

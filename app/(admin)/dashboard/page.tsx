import Link from 'next/link';
import { ArrowRight } from 'lucide-react';
import { createClient } from '@/lib/supabase/server';
import { redirect } from 'next/navigation';
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { formatMoney, formatDateTime } from '@/lib/format';

export default async function DashboardPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: venues } = await supabase
    .from('venues')
    .select('id, currency')
    .eq('owner_id', user.id);
  const venue = venues?.[0];
  if (!venue) redirect('/onboarding/profile');

  // KPIs: this week's paid bookings, gross, upcoming payout total.
  const weekStart = new Date();
  weekStart.setDate(weekStart.getDate() - weekStart.getDay()); // Sunday
  weekStart.setHours(0, 0, 0, 0);

  const { data: bookings } = await supabase
    .from('venue_bookings')
    .select('id, total_cents, payout_cents, status, created_at, slot_id')
    .eq('venue_id', venue.id)
    .gte('created_at', weekStart.toISOString());

  const paid = (bookings ?? []).filter((b) => b.status === 'paid' || b.status === 'completed');
  const grossThisWeek = paid.reduce((s, b) => s + b.total_cents, 0);
  const payoutThisWeek = paid.reduce((s, b) => s + b.payout_cents, 0);

  // Today's upcoming bookings
  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const todayEnd = new Date(todayStart);
  todayEnd.setDate(todayEnd.getDate() + 1);

  type TodayBookingRow = {
    id: string;
    status: string;
    total_cents: number;
    slot: { starts_at: string; ends_at: string; court: { name: string } | null } | null;
  };
  const { data: todayBookingsRaw } = await supabase
    .from('venue_bookings')
    .select(`
      id, status, total_cents,
      slot:venue_slots!inner(starts_at, ends_at, court:venue_courts(name))
    `)
    .eq('venue_id', venue.id)
    .gte('slot.starts_at', todayStart.toISOString())
    .lt('slot.starts_at', todayEnd.toISOString())
    .order('created_at', { ascending: false })
    .limit(8);
  const todayBookings = todayBookingsRaw as unknown as TodayBookingRow[] | null;

  return (
    <div className="px-8 py-8">
      <div className="flex items-end justify-between">
        <div>
          <h1 className="text-3xl font-medium tracking-tight">Dashboard</h1>
          <p className="mt-1 text-sm text-ink-dim">A snapshot. The grid is where the work happens.</p>
        </div>
        <Button asChild>
          <Link href="/calendar">
            Open calendar
            <ArrowRight className="h-4 w-4" />
          </Link>
        </Button>
      </div>

      <div className="mt-8 grid gap-4 sm:grid-cols-3">
        <Stat label="This week · paid bookings" value={String(paid.length)} />
        <Stat label="This week · gross" value={formatMoney(grossThisWeek, venue.currency)} accent />
        <Stat label="This week · your payout" value={formatMoney(payoutThisWeek, venue.currency)} />
      </div>

      <div className="mt-10">
        <Card>
          <CardHeader>
            <CardTitle>Today&apos;s bookings</CardTitle>
            <CardDescription>What captains expect to play, and where.</CardDescription>
          </CardHeader>
          <CardContent>
            {todayBookings && todayBookings.length > 0 ? (
              <ul className="divide-y divide-line/50">
                {todayBookings.map((b) => (
                  <li key={b.id} className="flex items-center justify-between py-3 text-sm">
                    <div>
                      <p className="font-medium text-ink">
                        {/* deno-lint-ignore no-explicit-any */}
                        {(b as any).slot?.court?.name ?? 'Court'}
                      </p>
                      <p className="text-xs text-ink-dim">
                        {/* deno-lint-ignore no-explicit-any */}
                        {formatDateTime((b as any).slot.starts_at)}
                      </p>
                    </div>
                    <div className="flex items-center gap-3">
                      <Badge tone={b.status === 'paid' ? 'brand' : 'neutral'} className="capitalize">
                        {b.status.replace('_', ' ')}
                      </Badge>
                      <span className="font-mono tnum text-ink-dim">
                        {formatMoney(b.total_cents, venue.currency)}
                      </span>
                    </div>
                  </li>
                ))}
              </ul>
            ) : (
              <p className="text-sm text-ink-dim">No bookings yet today. Quiet morning.</p>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

function Stat({ label, value, accent }: { label: string; value: string; accent?: boolean }) {
  return (
    <div className="card-base p-5">
      <p className="text-[11px] uppercase tracking-wide text-ink-mute">{label}</p>
      <p
        className={`mt-2 font-mono text-3xl tracking-tight tnum ${accent ? 'text-brand' : 'text-ink'}`}
      >
        {value}
      </p>
    </div>
  );
}

import { redirect } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { formatMoney, formatDateTime } from '@/lib/format';

export default async function SlotsPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: venue } = await supabase
    .from('venues')
    .select('id, name, currency')
    .eq('owner_id', user.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (!venue) redirect('/onboarding/profile');

  const now = new Date().toISOString();
  const { data: slots } = await supabase
    .from('venue_slots')
    .select(`
      id, starts_at, ends_at, price_cents, status,
      court:venue_courts(name)
    `)
    .eq('venue_id', venue.id)
    .gte('starts_at', now)
    .order('starts_at')
    .limit(50);

  return (
    <div className="px-8 py-8">
      <div className="flex items-end justify-between">
        <div>
          <h1 className="text-3xl font-medium tracking-tight">Slots</h1>
          <p className="mt-1 text-sm text-ink-dim">
            Upcoming inventory. Add or edit slots from the calendar.
          </p>
        </div>
        <Button asChild>
          <Link href="/calendar">Go to calendar</Link>
        </Button>
      </div>

      <Card className="mt-8">
        <CardHeader>
          <CardTitle>Next 50 slots</CardTitle>
          <CardDescription>Sorted by start time.</CardDescription>
        </CardHeader>
        <CardContent>
          {slots && slots.length > 0 ? (
            <table className="w-full text-sm">
              <thead className="border-b border-line/40 text-left text-[11px] uppercase tracking-wide text-ink-mute">
                <tr>
                  <th className="py-2">When</th>
                  <th>Court</th>
                  <th className="text-right">Price</th>
                  <th className="text-right">Status</th>
                </tr>
              </thead>
              <tbody>
                {slots.map((s) => (
                  <tr key={s.id} className="border-b border-line/30">
                    <td className="py-2.5 font-mono tnum text-[12px]">
                      {formatDateTime(s.starts_at)}
                    </td>
                    {/* deno-lint-ignore no-explicit-any */}
                    <td>{(s as any).court?.name ?? '—'}</td>
                    <td className="text-right font-mono tnum">
                      {formatMoney(s.price_cents, venue.currency)}
                    </td>
                    <td className="text-right">
                      <Badge
                        tone={
                          s.status === 'booked'
                            ? 'brand'
                            : s.status === 'held'
                              ? 'warn'
                              : s.status === 'closed' || s.status === 'cancelled'
                                ? 'danger'
                                : 'neutral'
                        }
                        className="capitalize"
                      >
                        {s.status.replace('_', ' ')}
                      </Badge>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <p className="py-6 text-sm text-ink-dim">
              No upcoming slots. Open the calendar to add some.
            </p>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

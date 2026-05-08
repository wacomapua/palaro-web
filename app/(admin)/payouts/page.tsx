import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { formatMoney } from '@/lib/format';

function formatDateRange(start: string, end: string): string {
  const s = new Date(start);
  const e = new Date(end);
  return `${s.toLocaleDateString('en-PH', { month: 'short', day: 'numeric' })}–${e.toLocaleDateString('en-PH', { month: 'short', day: 'numeric' })}`;
}

export default async function PayoutsPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: venue } = await supabase
    .from('venues')
    .select('id, currency, payout_method')
    .eq('owner_id', user.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (!venue) redirect('/onboarding/profile');

  const { data: payouts } = await supabase
    .from('venue_payouts')
    .select('id, period_start, period_end, gross_cents, fees_cents, net_cents, status, paid_at')
    .eq('venue_id', venue.id)
    .order('period_start', { ascending: false });

  // Upcoming = unpaid bookings in the current week.
  const today = new Date();
  const weekStart = new Date(today);
  weekStart.setDate(today.getDate() - today.getDay());
  weekStart.setHours(0, 0, 0, 0);

  const { data: pending } = await supabase
    .from('venue_bookings')
    .select('payout_cents')
    .eq('venue_id', venue.id)
    .eq('status', 'paid')
    .is('payout_id', null);

  const upcomingTotal = (pending ?? []).reduce((s, b) => s + b.payout_cents, 0);

  return (
    <div className="px-8 py-8">
      <h1 className="text-3xl font-medium tracking-tight">Payouts</h1>
      <p className="mt-1 text-sm text-ink-dim">
        Weekly payouts run every Monday for the previous week&apos;s bookings.
      </p>

      <Card className="mt-8">
        <CardHeader>
          <CardTitle>Next payout</CardTitle>
          <CardDescription>
            Estimated, based on bookings already paid by captains.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <p className="font-mono text-4xl tnum text-brand">
            {formatMoney(upcomingTotal, venue.currency)}
          </p>
          <p className="mt-2 text-xs text-ink-dim">
            Sent to{' '}
            {/* deno-lint-ignore no-explicit-any */}
            {(venue.payout_method as any)?.method === 'gcash'
              ? `GCash · ${(venue.payout_method as never as { gcash_number: string }).gcash_number}`
              : (venue.payout_method as never as { bank_name: string })?.bank_name ?? 'unset'}
          </p>
        </CardContent>
      </Card>

      <Card className="mt-6">
        <CardHeader>
          <CardTitle>History</CardTitle>
        </CardHeader>
        <CardContent>
          {payouts && payouts.length > 0 ? (
            <table className="w-full text-sm">
              <thead className="border-b border-line/40 text-left text-[11px] uppercase tracking-wide text-ink-mute">
                <tr>
                  <th className="py-2">Period</th>
                  <th className="text-right">Gross</th>
                  <th className="text-right">Fees</th>
                  <th className="text-right">Net</th>
                  <th className="text-right">Status</th>
                </tr>
              </thead>
              <tbody>
                {payouts.map((p) => (
                  <tr key={p.id} className="border-b border-line/30">
                    <td className="py-2.5">{formatDateRange(p.period_start, p.period_end)}</td>
                    <td className="text-right font-mono tnum">
                      {formatMoney(p.gross_cents, venue.currency)}
                    </td>
                    <td className="text-right font-mono tnum text-ink-dim">
                      {formatMoney(p.fees_cents, venue.currency)}
                    </td>
                    <td className="text-right font-mono tnum text-brand">
                      {formatMoney(p.net_cents, venue.currency)}
                    </td>
                    <td className="text-right">
                      <Badge tone={p.status === 'paid' ? 'brand' : 'neutral'} className="capitalize">
                        {p.status}
                      </Badge>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <p className="py-4 text-sm text-ink-dim">
              No payouts yet. Your first one will appear after your first paid booking.
            </p>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

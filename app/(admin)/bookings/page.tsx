import Link from 'next/link';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { formatMoney, formatDateTime } from '@/lib/format';
import type { VenueBooking } from '@/lib/types/db';

type BookingRow = Pick<
  VenueBooking,
  'id' | 'status' | 'total_cents' | 'payout_cents' | 'created_at' | 'party_size'
> & {
  slot: { starts_at: string; ends_at: string; court: { name: string } | null } | null;
  captain: { display_name: string | null; phone: string | null; email: string | null } | null;
};

export default async function BookingsPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: venue } = await supabase
    .from('venues')
    .select('id, currency')
    .eq('owner_id', user.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (!venue) redirect('/onboarding/profile');

  const { data: bookingsRaw } = await supabase
    .from('venue_bookings')
    .select(`
      id, status, total_cents, payout_cents, created_at, party_size,
      slot:venue_slots(starts_at, ends_at, court:venue_courts(name)),
      captain:profiles!captain_user_id(display_name, phone, email)
    `)
    .eq('venue_id', venue.id)
    .order('created_at', { ascending: false })
    .limit(100);
  const bookings = bookingsRaw as unknown as BookingRow[] | null;

  return (
    <div className="px-8 py-8">
      <h1 className="text-3xl font-medium tracking-tight">Bookings</h1>
      <p className="mt-1 text-sm text-ink-dim">
        Every reservation made on your venue.
      </p>

      <Card className="mt-8">
        <CardHeader>
          <CardTitle>Recent bookings</CardTitle>
          <CardDescription>{bookings?.length ?? 0} bookings</CardDescription>
        </CardHeader>
        <CardContent>
          {bookings && bookings.length > 0 ? (
            <table className="w-full text-sm">
              <thead className="border-b border-line/40 text-left text-[11px] uppercase tracking-wide text-ink-mute">
                <tr>
                  <th className="py-2">When played</th>
                  <th>Court</th>
                  <th>Captain</th>
                  <th className="text-right">Players</th>
                  <th className="text-right">Total</th>
                  <th className="text-right">Your cut</th>
                  <th className="text-right">Status</th>
                </tr>
              </thead>
              <tbody>
                {bookings.map((b) => (
                  <tr key={b.id} className="border-b border-line/30">
                    <td className="py-2.5 font-mono tnum text-[12px]">
                      {/* deno-lint-ignore no-explicit-any */}
                      {(b as any).slot?.starts_at
                        ? formatDateTime((b as any).slot.starts_at)
                        : '—'}
                    </td>
                    {/* deno-lint-ignore no-explicit-any */}
                    <td>{(b as any).slot?.court?.name ?? '—'}</td>
                    <td>
                      <Link
                        href={`/bookings/${b.id}`}
                        className="text-ink hover:text-brand"
                      >
                        {/* deno-lint-ignore no-explicit-any */}
                        {(b as any).captain?.display_name ?? '—'}
                      </Link>
                    </td>
                    <td className="text-right font-mono tnum text-ink-dim">{b.party_size ?? 1}</td>
                    <td className="text-right font-mono tnum">
                      {formatMoney(b.total_cents, venue.currency)}
                    </td>
                    <td className="text-right font-mono tnum text-ink-dim">
                      {formatMoney(b.payout_cents, venue.currency)}
                    </td>
                    <td className="text-right">
                      <Badge
                        tone={
                          b.status === 'paid' || b.status === 'completed'
                            ? 'brand'
                            : b.status === 'pending_payment'
                              ? 'warn'
                              : 'neutral'
                        }
                        className="capitalize"
                      >
                        {b.status.replace('_', ' ')}
                      </Badge>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <p className="py-6 text-sm text-ink-dim">No bookings yet.</p>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

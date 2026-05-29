import Link from 'next/link';
import { redirect, notFound } from 'next/navigation';
import { ArrowLeft } from 'lucide-react';
import { createClient } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { formatMoney, formatDateTime } from '@/lib/format';
import { computeRefund, formatRefundPolicy, DEFAULT_REFUND_POLICY } from '@/lib/refund';
import type { RefundPolicy, VenueBooking } from '@/lib/types/db';

type BookingWithJoins = VenueBooking & {
  venue: { name: string; currency: string; default_refund_policy: RefundPolicy } | null;
  slot: {
    starts_at: string;
    ends_at: string;
    refund_policy: RefundPolicy | null;
    court: { name: string } | null;
  } | null;
  captain: { display_name: string | null; phone: string | null; email: string | null } | null;
};

export default async function BookingDetail({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: bookingRaw } = await supabase
    .from('venue_bookings')
    .select(`
      *,
      venue:venues(name, currency, default_refund_policy),
      slot:venue_slots(starts_at, ends_at, refund_policy, court:venue_courts(name)),
      captain:profiles!captain_user_id(display_name, phone, email)
    `)
    .eq('id', id)
    .maybeSingle();

  const booking = bookingRaw as unknown as BookingWithJoins | null;
  if (!booking || !booking.venue || !booking.slot || !booking.slot.court || !booking.captain) {
    notFound();
  }

  const venue = booking.venue;
  const slot = { ...booking.slot, court: booking.slot.court };
  const captain = booking.captain;

  const policy = slot.refund_policy ?? venue.default_refund_policy ?? DEFAULT_REFUND_POLICY;
  const refund = computeRefund(booking.total_cents, slot.starts_at, policy);

  return (
    <div className="px-8 py-8 max-w-3xl">
      <Button asChild variant="plain" size="sm">
        <Link href="/bookings">
          <ArrowLeft className="h-4 w-4" />
          Back to bookings
        </Link>
      </Button>

      <h1 className="mt-4 text-3xl font-medium tracking-tight">Booking</h1>
      <p className="mt-1 text-sm text-ink-dim font-mono">{booking.id}</p>

      <div className="mt-8 grid gap-4">
        <Card>
          <CardHeader>
            <CardTitle>Status</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="flex items-center justify-between">
              <Badge
                tone={booking.status === 'paid' ? 'brand' : 'neutral'}
                className="capitalize"
              >
                {booking.status.replace('_', ' ')}
              </Badge>
              <span className="text-xs text-ink-dim">
                Created {formatDateTime(booking.created_at)}
              </span>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Game</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-2 text-sm">
            <Row label="Venue" value={venue.name} />
            <Row label="Court" value={slot.court.name} />
            <Row label="Players" value={String(booking.party_size ?? 1)} />
            <Row label="Start" value={formatDateTime(slot.starts_at)} />
            <Row label="End" value={formatDateTime(slot.ends_at)} />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Captain</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-2 text-sm">
            <Row label="Name" value={captain.display_name ?? '—'} />
            <Row label="Phone" value={captain.phone ?? '—'} mono />
            <Row label="Email" value={captain.email ?? '—'} />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Money</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-2 text-sm">
            <Row label="Total paid" value={formatMoney(booking.total_cents, venue.currency)} mono />
            <Row label="Platform fee (5%)" value={formatMoney(booking.platform_fee_cents, venue.currency)} mono />
            <Row label="Your payout" value={formatMoney(booking.payout_cents, venue.currency)} mono accent />
            {booking.refund_amount_cents > 0 && (
              <Row
                label="Refunded"
                value={formatMoney(booking.refund_amount_cents, venue.currency)}
                mono
              />
            )}
          </CardContent>
        </Card>

        {booking.status === 'paid' && (
          <Card>
            <CardHeader>
              <CardTitle>Refund preview</CardTitle>
            </CardHeader>
            <CardContent>
              <p className="text-sm text-ink-dim">
                If cancelled now, the captain would get back{' '}
                <span className="font-mono text-ink">
                  {formatMoney(refund.refundCents, venue.currency)}
                </span>{' '}
                ({refund.refundPct}%) — {refund.hoursBefore.toFixed(1)} hours before kickoff.
              </p>
              <ul className="mt-3 space-y-1 text-xs text-ink-mute">
                {formatRefundPolicy(policy).map((line, i) => (
                  <li key={i}>· {line}</li>
                ))}
              </ul>
              <Button variant="ghost" size="sm" className="mt-4" disabled>
                Issue refund (Phase 1.5)
              </Button>
            </CardContent>
          </Card>
        )}
      </div>
    </div>
  );
}

function Row({
  label,
  value,
  mono,
  accent,
}: {
  label: string;
  value: string;
  mono?: boolean;
  accent?: boolean;
}) {
  return (
    <div className="flex items-center justify-between border-b border-line/30 py-1.5 last:border-0">
      <span className="text-ink-dim">{label}</span>
      <span
        className={`${mono ? 'font-mono tnum' : ''} ${accent ? 'text-brand' : 'text-ink'}`}
      >
        {value}
      </span>
    </div>
  );
}

import { createClient } from '@/lib/supabase/server';
import { redirect } from 'next/navigation';
import { PayoutForm } from './form';

export default async function PayoutStep() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: venue } = await supabase
    .from('venues')
    .select('id, name, payout_method')
    .eq('owner_id', user.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!venue) redirect('/onboarding/venue');

  return (
    <section>
      <h1 className="text-2xl font-medium tracking-tight">Where should we send your money?</h1>
      <p className="mt-1 text-sm text-ink-dim">
        Payouts run every Monday for the previous week&apos;s bookings. We deduct the
        5% platform fee and send the rest to this account.
      </p>
      <div className="mt-6">
        <PayoutForm
          venueId={venue.id}
          initial={(venue.payout_method as never) ?? null}
        />
      </div>
    </section>
  );
}

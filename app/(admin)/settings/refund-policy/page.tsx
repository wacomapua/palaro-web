import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { dataOrThrow } from '@/lib/query';
import { DEFAULT_REFUND_POLICY } from '@/lib/refund';
import type { RefundPolicy } from '@/lib/types/db';
import { RefundPolicyForm } from './refund-policy-form';

export default async function RefundPolicyPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const venue = dataOrThrow(
    await supabase
      .from('venues')
      .select('id, default_refund_policy')
      .eq('owner_id', user.id)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle(),
    'venue',
  );
  if (!venue) redirect('/onboarding/profile');

  const policy = (venue.default_refund_policy as RefundPolicy | null) ?? DEFAULT_REFUND_POLICY;

  return (
    <div className="px-8 py-8 max-w-2xl">
      <h1 className="text-3xl font-medium tracking-tight">Refund policy</h1>
      <p className="mt-1 text-sm text-ink-dim">
        Default tiers for every slot without its own override (set one from
        the calendar). Changes apply to new bookings only.
      </p>

      <RefundPolicyForm venueId={venue.id} initialPolicy={policy} />
    </div>
  );
}

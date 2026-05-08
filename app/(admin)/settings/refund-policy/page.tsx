import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { formatRefundPolicy } from '@/lib/refund';
import type { RefundPolicy } from '@/lib/types/db';

export default async function RefundPolicyPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: venue } = await supabase
    .from('venues')
    .select('id, default_refund_policy')
    .eq('owner_id', user.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (!venue) redirect('/onboarding/profile');

  const policy = venue.default_refund_policy as RefundPolicy;

  return (
    <div className="px-8 py-8 max-w-2xl">
      <h1 className="text-3xl font-medium tracking-tight">Refund policy</h1>
      <p className="mt-1 text-sm text-ink-dim">
        Default tiers applied to every slot. You can override per-slot with a
        stricter policy from the calendar.
      </p>

      <Card className="mt-8">
        <CardHeader>
          <CardTitle>Current policy</CardTitle>
          <CardDescription>The standard tiered approach.</CardDescription>
        </CardHeader>
        <CardContent>
          <ul className="space-y-2 text-sm">
            {formatRefundPolicy(policy).map((line, i) => (
              <li key={i} className="flex items-center gap-2">
                <span className="inline-block h-1 w-1 rounded-full bg-brand" />
                {line}
              </li>
            ))}
          </ul>
          <p className="mt-6 text-xs text-ink-mute">
            Editing the policy is coming in Phase 1.5. For now, contact support if
            you need a custom policy.
          </p>
        </CardContent>
      </Card>
    </div>
  );
}

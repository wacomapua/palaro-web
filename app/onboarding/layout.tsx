import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { OnboardingProgress, type Step } from './progress';

export default async function OnboardingLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login?next=/onboarding/profile');

  // Decide the current step from server state. We don't need a separate
  // 'onboarding_state' table — the presence of profile fields and venues
  // tells us exactly where they are.
  const { data: profile } = await supabase
    .from('profiles')
    .select('display_name, phone')
    .eq('id', user.id)
    .maybeSingle();

  const { data: venues } = await supabase
    .from('venues')
    .select('id, name, sport, payout_method')
    .eq('owner_id', user.id)
    .order('created_at', { ascending: false });

  const venue = venues?.[0];
  const { data: courts } = venue
    ? await supabase.from('venue_courts').select('id').eq('venue_id', venue.id).limit(1)
    : { data: null };

  const profileDone = Boolean(profile?.display_name);
  const venueDone = Boolean(venue);
  const courtsDone = Boolean(courts && courts.length > 0);
  const payoutDone = Boolean(venue?.payout_method);

  const steps: Step[] = [
    { key: 'profile', label: 'You', done: profileDone },
    { key: 'venue', label: 'Venue', done: venueDone },
    { key: 'courts', label: 'Courts', done: courtsDone },
    { key: 'payout', label: 'Payout', done: payoutDone },
  ];

  return (
    <div className="min-h-screen bg-bg-0 text-ink">
      <header className="border-b border-line/50">
        <div className="mx-auto flex w-full max-w-4xl items-center justify-between px-6 py-4">
          <div className="flex items-center gap-2">
            <span className="grid h-6 w-6 place-items-center rounded-md bg-brand text-bg-0 font-mono text-[11px] font-bold">
              P
            </span>
            <span className="text-sm font-medium tracking-tight">
              palaro<span className="text-ink-mute">·club</span>
            </span>
          </div>
          <span className="text-xs text-ink-mute">{user.email}</span>
        </div>
      </header>

      <div className="mx-auto w-full max-w-2xl px-6 pt-10 pb-20">
        <OnboardingProgress steps={steps} />
        <div className="mt-10">{children}</div>
      </div>
    </div>
  );
}

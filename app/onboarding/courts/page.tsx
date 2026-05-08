import { createClient } from '@/lib/supabase/server';
import { redirect } from 'next/navigation';
import { CourtsBuilder } from './builder';

export default async function CourtsStep() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: venue } = await supabase
    .from('venues')
    .select('id, name, sport')
    .eq('owner_id', user.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!venue) redirect('/onboarding/venue');

  const { data: existingCourts } = await supabase
    .from('venue_courts')
    .select('id, name, kind, parent_court_id, sort_order')
    .eq('venue_id', venue.id)
    .order('sort_order');

  return (
    <section>
      <h1 className="text-2xl font-medium tracking-tight">Lay out your courts</h1>
      <p className="mt-1 text-sm text-ink-dim">
        Pick a starting layout for {venue.name}. We&apos;ll create the structure — you
        can rename anything before saving.
      </p>
      <div className="mt-6">
        <CourtsBuilder
          venueId={venue.id}
          venueSport={venue.sport}
          existingCourts={existingCourts ?? []}
        />
      </div>
    </section>
  );
}

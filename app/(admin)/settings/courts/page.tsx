import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { CourtsManager } from './courts-manager';

export default async function CourtsSettings() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: venue } = await supabase
    .from('venues')
    .select('id, sport')
    .eq('owner_id', user.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (!venue) redirect('/onboarding/profile');

  const { data: offered } = await supabase
    .from('venue_sports')
    .select('sport')
    .eq('venue_id', venue.id)
    .eq('active', true);
  const sports = [
    venue.sport,
    ...(offered ?? []).map((o) => o.sport).filter((s) => s !== venue.sport),
  ];

  const { data: courts } = await supabase
    .from('venue_courts')
    .select('id, venue_id, parent_court_id, sport, name, kind, capacity, active, sort_order')
    .eq('venue_id', venue.id)
    .order('sort_order');

  const maxSortOrder = (courts ?? []).reduce((m, c) => Math.max(m, c.sort_order), -1);

  return (
    <div className="px-8 py-8 max-w-3xl">
      <h1 className="text-3xl font-medium tracking-tight">Courts</h1>
      <p className="mt-1 text-sm text-ink-dim">
        Every bookable court, field, course, or lane. Add a new layout (e.g. another course or a
        driving range), rename, reorder, or deactivate what&apos;s out of service.
      </p>

      <div className="mt-8">
        <CourtsManager
          venueId={venue.id}
          sports={sports}
          courts={courts ?? []}
          maxSortOrder={maxSortOrder}
        />
      </div>
    </div>
  );
}

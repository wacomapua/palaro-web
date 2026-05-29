import { createClient } from '@/lib/supabase/server';
import { redirect } from 'next/navigation';
import { VenueForm } from './form';

export default async function VenueStep() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: venue } = await supabase
    .from('venues')
    .select('id, name, sport, address, city, phone, description')
    .eq('owner_id', user.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  let sports = venue ? [venue.sport] : undefined;
  if (venue) {
    const { data: offered } = await supabase
      .from('venue_sports')
      .select('sport')
      .eq('venue_id', venue.id)
      .eq('active', true);
    const extras = (offered ?? []).map((o) => o.sport).filter((s) => s !== venue.sport);
    sports = [venue.sport, ...extras];
  }

  return (
    <section>
      <h1 className="text-2xl font-medium tracking-tight">Tell us about your venue</h1>
      <p className="mt-1 text-sm text-ink-dim">
        You can edit any of this later from settings.
      </p>
      <div className="mt-6">
        <VenueForm
          initial={
            venue
              ? {
                  id: venue.id,
                  name: venue.name,
                  sport: venue.sport,
                  sports,
                  address: venue.address,
                  city: venue.city ?? '',
                  phone: venue.phone ?? '',
                  description: venue.description ?? '',
                }
              : null
          }
        />
      </div>
    </section>
  );
}

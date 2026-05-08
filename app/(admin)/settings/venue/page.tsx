import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { VenueForm } from '@/app/onboarding/venue/form';

export default async function VenueSettings() {
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
  if (!venue) redirect('/onboarding/profile');

  return (
    <div className="px-8 py-8 max-w-2xl">
      <h1 className="text-3xl font-medium tracking-tight">Venue settings</h1>
      <p className="mt-1 text-sm text-ink-dim">Edit your venue details.</p>

      <div className="mt-8">
        <VenueForm
          initial={{
            id: venue.id,
            name: venue.name,
            sport: venue.sport,
            address: venue.address,
            city: venue.city ?? '',
            phone: venue.phone ?? '',
            description: venue.description ?? '',
          }}
        />
      </div>
    </div>
  );
}

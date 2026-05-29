import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { CourtCalendar } from './court-calendar';

export default async function CalendarPage({
  searchParams,
}: {
  searchParams: Promise<{ d?: string }>;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: venue } = await supabase
    .from('venues')
    .select('id, name, sport, currency')
    .eq('owner_id', user.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!venue) redirect('/onboarding/profile');

  const params = await searchParams;
  const date = params.d ? new Date(params.d) : new Date();
  const dayStart = new Date(date);
  dayStart.setHours(0, 0, 0, 0);
  const dayEnd = new Date(dayStart);
  dayEnd.setDate(dayEnd.getDate() + 1);

  const { data: courts } = await supabase
    .from('venue_courts')
    .select('*')
    .eq('venue_id', venue.id)
    .order('sort_order');

  const { data: slots } = await supabase
    .from('venue_slots')
    .select('*')
    .eq('venue_id', venue.id)
    .gte('starts_at', dayStart.toISOString())
    .lt('starts_at', dayEnd.toISOString())
    .order('starts_at');

  const { data: bookings } = await supabase
    .from('venue_bookings')
    .select('id, slot_id, captain_user_id, team_id, status, party_size, captain:profiles!captain_user_id(display_name, avatar_url)')
    .eq('venue_id', venue.id)
    .in('status', ['paid', 'pending_payment', 'completed'])
    .in(
      'slot_id',
      (slots ?? []).map((s) => s.id),
    );

  return (
    <CourtCalendar
      venue={venue}
      date={dayStart.toISOString()}
      courts={courts ?? []}
      slots={slots ?? []}
      bookings={(bookings ?? []) as never}
    />
  );
}

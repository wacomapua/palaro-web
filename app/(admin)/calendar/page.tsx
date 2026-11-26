import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { dataOrThrow } from '@/lib/query';
import { DEFAULT_TIMEZONE, dayRangeUtc, ymdInTz } from '@/lib/tz';
import { CourtCalendar } from './court-calendar';

export default async function CalendarPage({
  searchParams,
}: {
  searchParams: Promise<{ d?: string; v?: string }>;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const venue = dataOrThrow(
    await supabase
      .from('venues')
      .select('id, name, sport, currency, timezone, default_refund_policy')
      .eq('owner_id', user.id)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle(),
    'venue',
  );

  if (!venue) redirect('/onboarding/profile');

  const tz = venue.timezone || DEFAULT_TIMEZONE;
  const params = await searchParams;
  // The day is a venue-local "YYYY-MM-DD"; its UTC window is derived in venue tz.
  const ymd = params.d ?? ymdInTz(new Date(), tz);
  const { start: dayStart, end: dayEnd } = dayRangeUtc(ymd, tz);

  // Every read throws on failure (dataOrThrow): read as empty, a column the
  // database lacks (holes before 20260601000001) would show every tee time
  // as open instead of an error.
  const courts = dataOrThrow(
    await supabase
      .from('venue_courts')
      .select('*')
      .eq('venue_id', venue.id)
      .order('sort_order'),
    'courts',
  );

  const slots = dataOrThrow(
    await supabase
      .from('venue_slots')
      .select('*')
      .eq('venue_id', venue.id)
      .gte('starts_at', dayStart.toISOString())
      .lt('starts_at', dayEnd.toISOString())
      .order('starts_at'),
    'slots',
  );

  const bookings = dataOrThrow(
    await supabase
      .from('venue_bookings')
      .select('id, slot_id, captain_user_id, team_id, status, party_size, holes, created_at, captain:profiles!captain_user_id(display_name, avatar_url)')
      .eq('venue_id', venue.id)
      .in('status', ['paid', 'pending_payment', 'completed'])
      .in(
        'slot_id',
        (slots ?? []).map((s) => s.id),
      )
      .order('created_at'),
    'bookings',
  );

  return (
    <CourtCalendar
      venue={{ ...venue, timezone: tz }}
      date={ymd}
      courts={courts ?? []}
      slots={slots ?? []}
      bookings={(bookings ?? []) as never}
      view={params.v === 'tee' || params.v === 'courts' ? params.v : null}
    />
  );
}

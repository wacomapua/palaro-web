import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { ScheduleEditor } from './schedule-editor';
import { ClosuresManager } from './closures-manager';

export default async function ScheduleSettings() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: venue } = await supabase
    .from('venues')
    .select('id, sport, currency, timezone')
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
    .select('id, sport, name, active, metadata')
    .eq('venue_id', venue.id)
    .order('sort_order');

  const { data: templates } = await supabase
    .from('venue_slot_templates')
    .select('id, court_id, day_of_week, start_time, end_time, slot_minutes, price_cents, active')
    .eq('venue_id', venue.id);

  const { data: closures } = await supabase
    .from('venue_closures')
    .select('id, court_id, starts_at, ends_at, reason')
    .eq('venue_id', venue.id)
    .order('starts_at', { ascending: false });

  return (
    <div className="px-8 py-8 max-w-3xl space-y-12">
      <div>
        <h1 className="text-3xl font-medium tracking-tight">Schedule</h1>
        <p className="mt-1 text-sm text-ink-dim">
          Set weekly opening hours, slot length, and pricing for each group of courts (a golf
          course and its range bays are set separately), then generate bookable slots in bulk.
          All times are in your venue&apos;s timezone ({venue.timezone}).
        </p>
        <div className="mt-8">
          <ScheduleEditor
            venueId={venue.id}
            currency={venue.currency}
            timezone={venue.timezone}
            sports={sports}
            courts={courts ?? []}
            templates={templates ?? []}
          />
        </div>
      </div>

      <div>
        <h2 className="text-xl font-medium tracking-tight">Closures &amp; blackout dates</h2>
        <p className="mt-1 text-sm text-ink-dim">
          Block off dates for maintenance, private events, or holidays. Every slot in the window
          is closed (a court closure also covers the courts it contains or belongs to), paid
          bookings are cancelled with a full refund, and generated slots skip it.
        </p>
        <div className="mt-6">
          <ClosuresManager
            venueId={venue.id}
            timezone={venue.timezone}
            currency={venue.currency}
            courts={courts ?? []}
            closures={closures ?? []}
          />
        </div>
      </div>
    </div>
  );
}

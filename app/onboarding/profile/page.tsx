import { createClient } from '@/lib/supabase/server';
import { redirect } from 'next/navigation';
import { ProfileForm } from './form';

export default async function ProfileStep() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: profile } = await supabase
    .from('profiles')
    .select('display_name, phone')
    .eq('id', user.id)
    .maybeSingle();

  return (
    <section>
      <h1 className="text-2xl font-medium tracking-tight">Tell us about you</h1>
      <p className="mt-1 text-sm text-ink-dim">
        We&apos;ll show this to captains who book your venue.
      </p>
      <div className="mt-6">
        <ProfileForm
          initial={{
            display_name: profile?.display_name ?? '',
            phone: profile?.phone ?? '',
          }}
        />
      </div>
    </section>
  );
}

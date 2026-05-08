'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { createClient } from '@/lib/supabase/client';

export function ProfileForm({ initial }: { initial: { display_name: string; phone: string } }) {
  const router = useRouter();
  const [displayName, setDisplayName] = useState(initial.display_name);
  const [phone, setPhone] = useState(initial.phone);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSubmitting(true);
    setError(null);

    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (!user) {
      setError('Session expired');
      setSubmitting(false);
      return;
    }

    const { error: updErr } = await supabase
      .from('profiles')
      .update({ display_name: displayName, phone: phone || null })
      .eq('id', user.id);

    setSubmitting(false);
    if (updErr) {
      setError(updErr.message);
      return;
    }
    router.push('/onboarding/venue');
  }

  return (
    <form onSubmit={onSubmit} className="card-base p-6 space-y-4">
      <div className="space-y-1.5">
        <Label htmlFor="display_name">Your name</Label>
        <Input
          id="display_name"
          required
          placeholder="Juan Dela Cruz"
          value={displayName}
          onChange={(e) => setDisplayName(e.target.value)}
        />
      </div>
      <div className="space-y-1.5">
        <Label htmlFor="phone">Phone (optional)</Label>
        <Input
          id="phone"
          type="tel"
          placeholder="+63 917 123 4567"
          value={phone}
          onChange={(e) => setPhone(e.target.value)}
        />
        <p className="text-xs text-ink-mute">Captains may contact you about bookings.</p>
      </div>
      {error && <p className="text-xs text-danger">{error}</p>}
      <div className="flex justify-end pt-2">
        <Button type="submit" disabled={submitting || !displayName}>
          {submitting ? 'Saving…' : 'Continue'}
        </Button>
      </div>
    </form>
  );
}

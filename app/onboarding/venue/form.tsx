'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { createClient } from '@/lib/supabase/client';
import { SPORT_CONFIGS } from '@/lib/sport-presets';
import type { VenueSport } from '@/lib/types/db';

interface VenueInitial {
  id: string;
  name: string;
  sport: VenueSport;
  address: string;
  city: string;
  phone: string;
  description: string;
}

function slugify(s: string): string {
  return s
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60);
}

export function VenueForm({ initial }: { initial: VenueInitial | null }) {
  const router = useRouter();
  const [name, setName] = useState(initial?.name ?? '');
  const [sport, setSport] = useState<VenueSport>(initial?.sport ?? 'football');
  const [address, setAddress] = useState(initial?.address ?? '');
  const [city, setCity] = useState(initial?.city ?? 'Manila');
  const [phone, setPhone] = useState(initial?.phone ?? '');
  const [description, setDescription] = useState(initial?.description ?? '');
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

    const baseSlug = slugify(name) || 'venue';
    // Append a short hash if collision; for v1 we just append a 4-char tail.
    const slug = initial?.id
      ? undefined
      : `${baseSlug}-${Math.random().toString(36).slice(2, 6)}`;

    const payload = {
      name,
      sport,
      address,
      city: city || null,
      phone: phone || null,
      description: description || null,
    };

    if (initial?.id) {
      const { error: updErr } = await supabase
        .from('venues')
        .update(payload)
        .eq('id', initial.id);
      if (updErr) {
        setError(updErr.message);
        setSubmitting(false);
        return;
      }
    } else {
      const { error: insErr } = await supabase.from('venues').insert({
        ...payload,
        slug,
        owner_id: user.id,
        status: 'pending_review',
      });
      if (insErr) {
        setError(insErr.message);
        setSubmitting(false);
        return;
      }
    }

    router.push('/onboarding/courts');
  }

  return (
    <form onSubmit={onSubmit} className="card-base p-6 space-y-5">
      <div className="space-y-1.5">
        <Label htmlFor="name">Venue name</Label>
        <Input
          id="name"
          required
          placeholder="Emperador Stadium"
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
      </div>

      <div className="space-y-2">
        <Label>Primary sport</Label>
        <div className="grid grid-cols-3 gap-2 sm:grid-cols-5">
          {SPORT_CONFIGS.map((c) => {
            const active = sport === c.sport;
            return (
              <button
                type="button"
                key={c.sport}
                onClick={() => setSport(c.sport)}
                className={`flex flex-col items-center gap-1 rounded-md border px-3 py-3 text-xs transition-colors ${
                  active
                    ? 'border-brand bg-brand/10 text-brand'
                    : 'border-line/70 bg-bg-1 text-ink-dim hover:border-line'
                }`}
              >
                <span className="text-xl leading-none">{c.emoji}</span>
                {c.label}
              </button>
            );
          })}
        </div>
        <p className="text-xs text-ink-mute">
          Multi-sport venues: pick the primary sport now; you can add courts for other
          sports from settings later.
        </p>
      </div>

      <div className="space-y-1.5">
        <Label htmlFor="address">Address</Label>
        <Input
          id="address"
          required
          placeholder="32nd St, McKinley Hill, Taguig"
          value={address}
          onChange={(e) => setAddress(e.target.value)}
        />
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-1.5">
          <Label htmlFor="city">City</Label>
          <Input
            id="city"
            value={city}
            onChange={(e) => setCity(e.target.value)}
          />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="phone">Phone (optional)</Label>
          <Input
            id="phone"
            type="tel"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
          />
        </div>
      </div>

      <div className="space-y-1.5">
        <Label htmlFor="description">Description (optional)</Label>
        <textarea
          id="description"
          rows={3}
          className="input-base resize-y"
          placeholder="Floodlit synthetic turf. Locker rooms. 2 hour blocks."
          value={description}
          onChange={(e) => setDescription(e.target.value)}
        />
      </div>

      {error && <p className="text-xs text-danger">{error}</p>}

      <div className="flex justify-between pt-2">
        <Button type="button" variant="ghost" onClick={() => router.push('/onboarding/profile')}>
          Back
        </Button>
        <Button type="submit" disabled={submitting || !name || !address}>
          {submitting ? 'Saving…' : 'Continue to courts'}
        </Button>
      </div>
    </form>
  );
}

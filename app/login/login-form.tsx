'use client';

import { use, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { createClient } from '@/lib/supabase/client';

export function LoginForm({
  searchParams,
}: {
  searchParams: Promise<{ next?: string; error?: string }>;
}) {
  const params = use(searchParams);
  const [email, setEmail] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(params.error ?? null);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSubmitting(true);
    setError(null);

    const supabase = createClient();
    const next = params.next ?? '/dashboard';
    // PKCE flow: Supabase appends ?code=… to redirect_to. We must land on
    // /auth/callback so the route can exchangeCodeForSession before routing
    // the user on to `next`.
    const redirectTo = `${window.location.origin}/auth/callback?next=${encodeURIComponent(next)}`;

    const { error: signInErr } = await supabase.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: redirectTo, shouldCreateUser: true },
    });

    setSubmitting(false);
    if (signInErr) {
      setError(signInErr.message);
      return;
    }
    setSent(true);
  }

  if (sent) {
    return (
      <div className="card-base p-5 text-sm">
        <p className="text-ink">
          Check your inbox — we sent a magic link to <span className="text-brand">{email}</span>.
        </p>
        <p className="mt-2 text-ink-dim">
          The link will sign you in and drop you on your dashboard.
        </p>
      </div>
    );
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <div className="space-y-1.5">
        <Label htmlFor="email">Email</Label>
        <Input
          id="email"
          type="email"
          required
          autoComplete="email"
          placeholder="you@venue.com"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />
      </div>
      {error && <p className="text-xs text-danger">{error}</p>}
      <Button type="submit" className="w-full" disabled={submitting}>
        {submitting ? 'Sending…' : 'Send magic link'}
      </Button>
    </form>
  );
}

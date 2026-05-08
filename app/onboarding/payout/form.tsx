'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { createClient } from '@/lib/supabase/client';
import type { PayoutMethod } from '@/lib/types/db';

export function PayoutForm({
  venueId,
  initial,
}: {
  venueId: string;
  initial: PayoutMethod | null;
}) {
  const router = useRouter();
  const [method, setMethod] = useState<'gcash' | 'bank'>(initial?.method ?? 'gcash');
  const [gcash, setGcash] = useState(initial?.gcash_number ?? '');
  const [bankName, setBankName] = useState(initial?.bank_name ?? '');
  const [accountNo, setAccountNo] = useState(initial?.account_no ?? '');
  const [accountName, setAccountName] = useState(initial?.account_name ?? '');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSubmitting(true);
    setError(null);

    const payload: PayoutMethod =
      method === 'gcash'
        ? { method: 'gcash', gcash_number: gcash, account_name: accountName || undefined }
        : {
            method: 'bank',
            bank_name: bankName,
            account_no: accountNo,
            account_name: accountName,
          };

    const supabase = createClient();
    // Setting payout_method on a venue marks onboarding as complete; we also
    // optimistically activate so captains can book it. Production may want a
    // human review step here — that's just flipping the default.
    const { error: updErr } = await supabase
      .from('venues')
      .update({ payout_method: payload as never, status: 'active' })
      .eq('id', venueId);

    setSubmitting(false);
    if (updErr) {
      setError(updErr.message);
      return;
    }
    router.push('/calendar');
  }

  return (
    <form onSubmit={onSubmit} className="card-base p-6 space-y-5">
      <div className="grid grid-cols-2 gap-2">
        {(['gcash', 'bank'] as const).map((m) => {
          const active = method === m;
          return (
            <button
              type="button"
              key={m}
              onClick={() => setMethod(m)}
              className={`rounded-md border px-4 py-3 text-sm transition-colors ${
                active
                  ? 'border-brand bg-brand/10 text-brand'
                  : 'border-line/70 bg-bg-1 text-ink-dim hover:border-line'
              }`}
            >
              {m === 'gcash' ? 'GCash' : 'Bank transfer'}
            </button>
          );
        })}
      </div>

      {method === 'gcash' && (
        <>
          <div className="space-y-1.5">
            <Label htmlFor="gcash">GCash number</Label>
            <Input
              id="gcash"
              required
              type="tel"
              placeholder="09171234567"
              value={gcash}
              onChange={(e) => setGcash(e.target.value)}
            />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="account_name">Account name (optional)</Label>
            <Input
              id="account_name"
              value={accountName}
              onChange={(e) => setAccountName(e.target.value)}
              placeholder="Juan D. Cruz"
            />
          </div>
        </>
      )}

      {method === 'bank' && (
        <>
          <div className="space-y-1.5">
            <Label htmlFor="bank_name">Bank</Label>
            <Input
              id="bank_name"
              required
              placeholder="BPI"
              value={bankName}
              onChange={(e) => setBankName(e.target.value)}
            />
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-1.5">
              <Label htmlFor="account_no">Account number</Label>
              <Input
                id="account_no"
                required
                value={accountNo}
                onChange={(e) => setAccountNo(e.target.value)}
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="account_name">Account name</Label>
              <Input
                id="account_name"
                required
                value={accountName}
                onChange={(e) => setAccountName(e.target.value)}
              />
            </div>
          </div>
        </>
      )}

      {error && <p className="text-xs text-danger">{error}</p>}

      <div className="flex justify-between pt-2">
        <Button type="button" variant="ghost" onClick={() => router.push('/onboarding/courts')}>
          Back
        </Button>
        <Button type="submit" disabled={submitting}>
          {submitting ? 'Saving…' : 'Finish · go to calendar'}
        </Button>
      </div>

      <p className="text-xs text-ink-mute">
        We&apos;ll need to verify your account before the first payout. Most accounts
        are approved within 24 hours.
      </p>
    </form>
  );
}

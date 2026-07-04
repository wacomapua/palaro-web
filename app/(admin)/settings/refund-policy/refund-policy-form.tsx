'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { createClient } from '@/lib/supabase/client';
import { RefundPolicyEditor, normalizeTiers } from '@/components/refund-policy-editor';
import { formatRefundPolicy } from '@/lib/refund';
import type { RefundPolicy } from '@/lib/types/db';

export function RefundPolicyForm({
  venueId,
  initialPolicy,
}: {
  venueId: string;
  initialPolicy: RefundPolicy;
}) {
  const router = useRouter();
  const [policy, setPolicy] = useState<RefundPolicy>(initialPolicy);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  const previewPolicy: RefundPolicy = { tiers: normalizeTiers(policy.tiers) };

  async function save() {
    setSaving(true);
    setError(null);
    setSaved(false);
    const supabase = createClient();
    const { error: e } = await supabase
      .from('venues')
      .update({ default_refund_policy: previewPolicy })
      .eq('id', venueId);
    setSaving(false);
    if (e) {
      setError(e.message);
      return;
    }
    setPolicy(previewPolicy);
    setSaved(true);
    router.refresh();
  }

  return (
    <Card className="mt-8">
      <CardHeader>
        <CardTitle>Default refund policy</CardTitle>
        <CardDescription>
          Applied to every booking, most-lenient first. A customer who cancels
          earlier than a tier&apos;s threshold gets that tier&apos;s refund.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-6">
        <RefundPolicyEditor
          value={policy}
          onChange={(p) => {
            setPolicy(p);
            setSaved(false);
          }}
          disabled={saving}
        />

        <div className="rounded-md border border-line/60 bg-bg-2/40 p-3">
          <p className="mb-2 text-xs uppercase tracking-wide text-ink-mute">Preview</p>
          <ul className="space-y-1.5 text-sm">
            {formatRefundPolicy(previewPolicy).map((line, i) => (
              <li key={i} className="flex items-center gap-2">
                <span className="inline-block h-1 w-1 rounded-full bg-brand" />
                {line}
              </li>
            ))}
          </ul>
        </div>

        {error && <p className="text-xs text-danger">{error}</p>}

        <div className="flex items-center gap-3">
          <Button onClick={save} disabled={saving || policy.tiers.length === 0}>
            {saving ? 'Saving…' : 'Save policy'}
          </Button>
          {saved && <span className="text-xs text-brand">Saved.</span>}
        </div>
      </CardContent>
    </Card>
  );
}

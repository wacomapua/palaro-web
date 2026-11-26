'use client';

import { useRouter } from 'next/navigation';
import { Button } from '@/components/ui/button';
import { CourtLayoutBuilder } from '@/components/court-layout-builder';
import type { VenueSport } from '@/lib/types/db';

interface ExistingCourt {
  id: string;
  name: string;
  kind: string | null;
  parent_court_id: string | null;
  sort_order: number;
}

export function CourtsBuilder({
  venueId,
  sports,
  existingCourts,
}: {
  venueId: string;
  sports: VenueSport[];
  existingCourts: ExistingCourt[];
}) {
  const router = useRouter();

  // Onboarding only seeds the initial layout. Editing/adding later happens in
  // Settings → Courts, so if courts already exist we just move on.
  if (existingCourts.length > 0) {
    return (
      <div className="card-base p-6">
        <p className="text-sm text-ink">
          You already have {existingCourts.length} court{existingCourts.length === 1 ? '' : 's'}{' '}
          set up. Add or edit them anytime from Settings → Courts.
        </p>
        <div className="mt-4 flex justify-between">
          <Button variant="ghost" onClick={() => router.push('/onboarding/venue')}>
            Back
          </Button>
          <Button onClick={() => router.push('/onboarding/payout')}>Continue to payout</Button>
        </div>
      </div>
    );
  }

  return (
    <CourtLayoutBuilder
      venueId={venueId}
      sports={sports}
      seedDefaults
      submitLabel="Save courts & continue"
      onCommitted={() => router.push('/onboarding/payout')}
      secondaryAction={
        <Button variant="ghost" onClick={() => router.push('/onboarding/venue')}>
          Back
        </Button>
      }
    />
  );
}

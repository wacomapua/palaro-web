import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';

export default function TeamSettings() {
  return (
    <div className="px-8 py-8 max-w-2xl">
      <h1 className="text-3xl font-medium tracking-tight">Team</h1>
      <p className="mt-1 text-sm text-ink-dim">
        Invite co-owners to manage your venue with you.
      </p>

      <Card className="mt-8">
        <CardHeader>
          <CardTitle>Coming in Phase 3</CardTitle>
        </CardHeader>
        <CardContent>
          <p className="text-sm text-ink-dim">
            Single-owner accounts only for v1. We&apos;ll add co-owner invites once
            we&apos;ve seen how single-owner venues actually use the platform.
          </p>
        </CardContent>
      </Card>
    </div>
  );
}

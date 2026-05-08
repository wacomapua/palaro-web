import Link from 'next/link';
import { LoginForm } from '../login/login-form';

// Signup uses the same magic-link form (Supabase Auth's signInWithOtp +
// shouldCreateUser auto-creates an auth.users row on first link click).
// New profiles flow to /onboarding from /auth/callback.
export default function SignupPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string; error?: string }>;
}) {
  return (
    <div className="grid min-h-screen place-items-center bg-bg-0 px-6">
      <div className="w-full max-w-sm">
        <div className="mb-8 flex items-center gap-2">
          <span className="grid h-7 w-7 place-items-center rounded-md bg-brand text-bg-0 font-mono text-[13px] font-bold">
            P
          </span>
          <span className="text-sm font-medium tracking-tight">
            palaro<span className="text-ink-mute">·club</span>
          </span>
        </div>
        <h1 className="text-2xl font-medium tracking-tight">Claim your venue</h1>
        <p className="mt-1 text-sm text-ink-dim">
          Takes about three minutes. We&apos;ll need: your venue name, address, courts,
          and your GCash for payouts.
        </p>

        <div className="mt-8">
          <LoginForm searchParams={searchParams} />
        </div>

        <p className="mt-8 text-xs text-ink-mute">
          Already have an account?{' '}
          <Link href="/login" className="text-brand hover:underline">
            Sign in
          </Link>
        </p>
      </div>
    </div>
  );
}

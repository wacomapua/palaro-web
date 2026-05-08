import Link from 'next/link';
import { LoginForm } from './login-form';

export default function LoginPage({
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
        <h1 className="text-2xl font-medium tracking-tight">Sign in</h1>
        <p className="mt-1 text-sm text-ink-dim">
          Use your venue email. We&apos;ll send you a magic link.
        </p>

        <div className="mt-8">
          <LoginForm searchParams={searchParams} />
        </div>

        <p className="mt-8 text-xs text-ink-mute">
          New here?{' '}
          <Link href="/signup" className="text-brand hover:underline">
            Claim your venue
          </Link>
        </p>
      </div>
    </div>
  );
}

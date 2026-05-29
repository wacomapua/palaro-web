import { NextResponse } from 'next/server';
import type { EmailOtpType } from '@supabase/supabase-js';
import { createClient } from '@/lib/supabase/server';

// Handles BOTH Supabase auth-link styles:
//   - OAuth / PKCE:        ?code=…
//   - OTP / magic link:    ?token_hash=…&type=email
// Default email templates use the OTP form; OAuth providers use the code form.
// We accept either so the same redirect URL works for both.
export async function GET(request: Request) {
  const url = new URL(request.url);
  const { searchParams } = url;
  // Behind a proxy (Railway/Vercel), request.url's host is the internal bind
  // address (e.g. localhost:8080), so url.origin would redirect users there.
  // Derive the public origin from the proxy's forwarded headers; fall back to
  // url.origin for local dev where there is no proxy.
  const forwardedHost = request.headers.get('x-forwarded-host');
  const forwardedProto = request.headers.get('x-forwarded-proto') ?? url.protocol.replace(':', '');
  const origin = forwardedHost ? `${forwardedProto}://${forwardedHost}` : url.origin;
  const code = searchParams.get('code');
  const tokenHash = searchParams.get('token_hash');
  const type = searchParams.get('type') as EmailOtpType | null;
  const next = searchParams.get('next') ?? '/dashboard';

  const supabase = await createClient();

  let authErr: { message: string } | null = null;

  if (code) {
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    authErr = error ?? null;
  } else if (tokenHash && type) {
    const { error } = await supabase.auth.verifyOtp({ type, token_hash: tokenHash });
    authErr = error ?? null;
  } else {
    return NextResponse.redirect(`${origin}/login?error=missing_token`);
  }

  if (authErr) {
    return NextResponse.redirect(`${origin}/login?error=${encodeURIComponent(authErr.message)}`);
  }

  // Routing: send brand-new users (no venue yet) to onboarding.
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (user) {
    const { data: venues } = await supabase
      .from('venues')
      .select('id')
      .eq('owner_id', user.id)
      .limit(1);
    if (!venues || venues.length === 0) {
      return NextResponse.redirect(`${origin}/onboarding/profile`);
    }
  }
  return NextResponse.redirect(`${origin}${next}`);
}

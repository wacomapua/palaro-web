// Where to send a user after sign in, from the ?next= query value.
//
// The callback redirects to `${origin}${next}`, so anything that is not a
// plain path on this site would send a freshly signed in user elsewhere:
// "@evil.com" makes evil.com the host, ".evil.com" a subdomain of it.
// Accept only a path that starts with one "/" (not "//" or "/\", which
// browsers read as another host), with no tab, CR, LF or other control
// character (the URL parser drops those, so "/<tab>/evil.com" becomes
// "//evil.com"). Anything else goes to the site root.
export function safeNext(raw: string | null): string {
  if (raw === null) return '/dashboard';
  const isLocalPath = raw.startsWith('/') && raw[1] !== '/' && raw[1] !== '\\';
  return isLocalPath && !/[\u0000-\u001f\u007f]/.test(raw) ? raw : '/';
}

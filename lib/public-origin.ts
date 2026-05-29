// Resolve the public-facing origin for server-side redirects.
//
// Behind a proxy (Railway, Vercel, Fly, etc.) `new URL(request.url).origin`
// reflects the internal bind address (e.g. http://localhost:8080), so redirects
// built from it send users to a dead local URL. Prefer the proxy's forwarded
// headers; fall back to the request origin for local dev where no proxy exists.
export function publicOrigin(request: Request): string {
  const url = new URL(request.url);
  const host = request.headers.get('x-forwarded-host');
  const proto = request.headers.get('x-forwarded-proto') ?? url.protocol.replace(':', '');
  return host ? `${proto}://${host}` : url.origin;
}

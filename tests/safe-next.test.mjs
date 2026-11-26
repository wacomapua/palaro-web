import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { safeNext } from '../lib/safe-next.ts';

// The callback redirects to `${origin}${next}`, so this is the URL a user
// lands on after signing in.
const ORIGIN = 'https://palaro.club';
const landing = (raw) => `${ORIGIN}${safeNext(raw)}`;

const OFF_SITE = [
  '@evil.com', // https://palaro.club@evil.com is evil.com
  '.evil.com', // https://palaro.club.evil.com is a subdomain of evil.com
  '//evil.com',
  '/\\evil.com',
  'https://evil.com',
  '',
  '/\t/evil.com', // the URL parser drops tab, CR and LF, leaving //evil.com
  '/\n/evil.com',
  '/\r/evil.com',
];

for (const raw of OFF_SITE) {
  test(`next=${JSON.stringify(raw)} lands on the origin root`, () => {
    assert.equal(landing(raw), `${ORIGIN}/`);
  });
}

test('a same site path keeps its query string', () => {
  assert.equal(landing('/bookings?x=1'), `${ORIGIN}/bookings?x=1`);
});

test('no next keeps the dashboard default', () => {
  assert.equal(landing(null), `${ORIGIN}/dashboard`);
});

test('the auth callback reads next only through safeNext', async () => {
  const src = await readFile(new URL('../app/auth/callback/route.ts', import.meta.url), 'utf8');
  assert.match(src, /import \{ safeNext \} from '@\/lib\/safe-next';/);
  assert.equal(src.match(/searchParams\.get\('next'\)/g)?.length, 1);
  assert.match(src, /const next = safeNext\(searchParams\.get\('next'\)\);/);
});

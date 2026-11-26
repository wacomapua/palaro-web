import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

// Advisories GHSA for Next.js Image Optimization RCE (SVG and AVIF) are
// fixed in 15.5.28. Fail if the installed version falls below that floor.
const NEXT_FLOOR = [15, 5, 28];

function atLeast(version, floor) {
  const parts = version.split('-')[0].split('.').map(Number);
  for (let i = 0; i < floor.length; i++) {
    if (parts[i] > floor[i]) return true;
    if (parts[i] < floor[i]) return false;
  }
  return true;
}

test('installed next is at or above the patched floor', () => {
  const { version } = require('next/package.json');
  assert.ok(atLeast(version, NEXT_FLOOR), `next ${version} is below ${NEXT_FLOOR.join('.')}`);
});

test('image optimizer only allows the configured Supabase storage host', async () => {
  process.env.NEXT_PUBLIC_SUPABASE_URL = 'https://abcdefghijklmnop.supabase.co';
  const { default: config } = await import(`../next.config.ts?case=${Date.now()}`);
  const patterns = config.images?.remotePatterns ?? [];

  for (const p of patterns) {
    assert.ok(!p.hostname.includes('*'), `wildcard hostname not allowed: ${p.hostname}`);
  }
  assert.deepEqual(
    patterns.map((p) => ({ protocol: p.protocol, hostname: p.hostname, pathname: p.pathname })),
    [{ protocol: 'https', hostname: 'abcdefghijklmnop.supabase.co', pathname: '/storage/v1/object/public/**' }],
  );
});

test('image optimizer allows nothing remote when the Supabase URL is unset', async () => {
  delete process.env.NEXT_PUBLIC_SUPABASE_URL;
  const { default: config } = await import(`../next.config.ts?case=unset${Date.now()}`);
  assert.deepEqual(config.images?.remotePatterns ?? [], []);
});

test('responses do not advertise Next.js and carry the baseline security headers', async () => {
  const { default: config } = await import(`../next.config.ts?case=headers${Date.now()}`);
  assert.equal(config.poweredByHeader, false, 'poweredByHeader should be false');
  assert.equal(typeof config.headers, 'function', 'next.config has no headers()');

  const rules = await config.headers();
  const everyPath = rules.filter((r) => r.source === '/:path*');
  assert.equal(everyPath.length, 1, 'expected one headers rule for every path');
  const headers = Object.fromEntries(everyPath[0].headers.map((h) => [h.key, h.value]));
  assert.deepEqual(headers, {
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
    'X-Frame-Options': 'DENY',
  });
});

// The tests import next.config.ts directly, which needs Node's native type
// stripping (on by default from 22.18). supabase-js also needs Node 22.
test('package.json pins Node 22 at 22.18 or newer', async () => {
  const { readFile } = await import('node:fs/promises');
  const pkg = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  const range = pkg.engines?.node;
  assert.ok(range, 'engines.node is not set');
  const m = /^\^(\d+)\.(\d+)\.(\d+)$/.exec(range);
  assert.ok(m, `engines.node should be a caret range, got ${range}`);
  assert.ok(atLeast(`${m[1]}.${m[2]}.${m[3]}`, [22, 18, 0]) && Number(m[1]) === 22, `engines.node ${range} should be ^22.18.0 or a later 22.x`);
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

// A server page, layout or route that reads venues and then redirects on a
// missing row must not read a failed query as "no venue" (that sends owners to
// onboarding whenever the database errors). Such files must go through
// dataOrThrow from lib/query.ts.
const ROOT = fileURLToPath(new URL('..', import.meta.url));
const APP = join(ROOT, 'app');

function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? walk(path) : [path];
  });
}

function offenders() {
  return walk(APP)
    .filter((f) => /\.(ts|tsx)$/.test(f))
    .filter((f) => {
      const src = readFileSync(f, 'utf8');
      const isClient = /^\s*['"]use client['"]/m.test(src.slice(0, 200));
      const readsVenues = /from\(\s*['"]venues['"]\s*\)\s*\.select\(/.test(src.replace(/\s+/g, ' '));
      const redirects = /\bredirect\(/.test(src);
      return !isClient && readsVenues && redirects && !src.includes('dataOrThrow(');
    })
    .map((f) => relative(ROOT, f))
    .sort();
}

test('server files that read venues and redirect use dataOrThrow', () => {
  assert.deepEqual(offenders(), []);
});

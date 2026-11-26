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

// Review of PR #12, finding 4: these pages read the golf columns (holes,
// price_per_player_9_cents, price_9_cents). If the web app is deployed
// before 20260601000001 is applied, PostgREST answers 400 for an unknown
// column; read as empty data, tee times would all show Open, bookings would
// look empty and the schedule editor would save an empty week over the saved
// templates. Every read on them must go through dataOrThrow, so a failed
// load renders the error page instead.
const GOLF_PAGES = [
  'app/(admin)/calendar/page.tsx',
  'app/(admin)/bookings/page.tsx',
  'app/(admin)/bookings/[id]/page.tsx',
  'app/(admin)/settings/schedule/page.tsx',
];

function unguardedReads(file) {
  const src = readFileSync(join(ROOT, file), 'utf8').replace(/\s+/g, ' ');
  const reads = src.match(/await supabase ?\.from\(/g) ?? [];
  const guarded = src.match(/dataOrThrow\( ?await supabase ?\.from\(/g) ?? [];
  return { reads: reads.length, unguarded: reads.length - guarded.length };
}

test('the calendar, bookings and schedule pages throw on any failed read', () => {
  const found = Object.fromEntries(GOLF_PAGES.map((f) => [f, unguardedReads(f)]));
  for (const [file, { reads }] of Object.entries(found)) assert.ok(reads > 0, `${file} has no reads to check`);
  assert.deepEqual(
    Object.entries(found).filter(([, r]) => r.unguarded > 0).map(([f, r]) => `${f}: ${r.unguarded} of ${r.reads}`),
    [],
  );
});

# palaro.club — venue dashboard

Sister app to [team-manager](../team-manager). The web side of palaro.club,
where venue owners list courts, post slots, see bookings, and get paid weekly.

*Palaro* (Tagalog) — game, match, contest. Where the games happen.

## Stack

- Next.js 15 (App Router) + TypeScript
- Tailwind v3 + shadcn/ui-style primitives
- TanStack Query v5
- @supabase/ssr (shared Supabase project with team-manager)
- PayMongo via the team-manager edge functions

## Setup

```bash
pnpm install
cp .env.example .env.local
# fill in NEXT_PUBLIC_SUPABASE_URL, anon key, PayMongo keys
pnpm dev   # binds :3008
```

Migrations live in `../team-manager/supabase/migrations/`. Apply once and both
apps see the schema.

## Routes

- `/` — marketing landing
- `/login`, `/signup` — magic-link auth (lands at `/auth/confirm`)
- `/onboarding/{profile,venue,courts,payout}` — multi-step setup
- `/dashboard` — KPIs and today's bookings
- `/calendar` — court × time grid (default after login)
- `/slots` — upcoming slot list
- `/bookings`, `/bookings/[id]` — history + detail
- `/payouts` — weekly payout history
- `/settings/{venue,refund-policy,team}`

## Deployment

Vercel. `NEXT_PUBLIC_*` go into Vercel env; `SUPABASE_SERVICE_ROLE_KEY` stays
server-only. Production domain: `palaro.club`.

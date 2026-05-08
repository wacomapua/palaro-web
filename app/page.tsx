import Link from 'next/link';
import { ArrowRight, CalendarDays, ShieldCheck, Wallet } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';

export default function MarketingPage() {
  return (
    <div className="min-h-screen bg-bg-0 text-ink">
      {/* Top nav */}
      <nav className="mx-auto flex w-full max-w-6xl items-center justify-between px-6 py-5">
        <div className="flex items-center gap-2">
          <span className="grid h-7 w-7 place-items-center rounded-md bg-brand text-bg-0 font-mono text-[13px] font-bold">
            P
          </span>
          <span className="text-sm font-medium tracking-tight">
            palaro<span className="text-ink-mute">·club</span>
          </span>
          <Badge tone="brand" className="ml-2">v1 beta</Badge>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="plain" size="sm" asChild>
            <Link href="/login">Sign in</Link>
          </Button>
          <Button variant="brand" size="sm" asChild>
            <Link href="/signup">Claim your venue</Link>
          </Button>
        </div>
      </nav>

      {/* Hero */}
      <section className="mx-auto w-full max-w-6xl px-6 pt-16 pb-20">
        <div className="grid gap-12 lg:grid-cols-[1.1fr_1fr] lg:items-center">
          <div>
            <p className="mb-5 inline-flex items-center gap-2 rounded-full border border-line bg-bg-1 px-3 py-1 text-xs text-ink-dim">
              <span className="inline-block h-1.5 w-1.5 rounded-full bg-brand" />
              Palaro · for pitch, court & pickleball owners
            </p>
            <h1 className="text-4xl font-medium tracking-tight text-ink sm:text-6xl">
              Stop chasing
              <br />
              <span className="text-brand">payment screenshots.</span>
            </h1>
            <p className="mt-6 max-w-xl text-[15px] leading-7 text-ink-dim">
              List your slots, set your prices, and let team captains book and pay
              upfront. We collect via PayMongo, take 5%, and pay you weekly. No
              spreadsheets. No “Maam, na-deposit ko na po” screenshots at 11pm.
            </p>
            <div className="mt-8 flex flex-wrap items-center gap-3">
              <Button size="lg" asChild>
                <Link href="/signup" className="group">
                  Claim your venue
                  <ArrowRight className="h-4 w-4 transition-transform group-hover:translate-x-0.5" />
                </Link>
              </Button>
              <Button variant="ghost" size="lg" asChild>
                <Link href="/login">I already have an account</Link>
              </Button>
            </div>
            <div className="mt-10 flex items-center gap-6 text-xs text-ink-mute">
              <span>5% per booking</span>
              <span className="h-1 w-1 rounded-full bg-line" />
              <span>Weekly payout to GCash</span>
              <span className="h-1 w-1 rounded-full bg-line" />
              <span>No setup fee</span>
            </div>
          </div>

          {/* Hero artwork — a stylised calendar grid screenshot. Pure CSS/SVG so
              it stays sharp + theme-able and we don't need a static image yet. */}
          <CalendarHeroMock />
        </div>
      </section>

      {/* Features */}
      <section className="border-t border-line/50 bg-bg-1/40">
        <div className="mx-auto w-full max-w-6xl px-6 py-20">
          <div className="grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
            <Feature
              icon={<CalendarDays className="h-5 w-5" />}
              title="A grid you'll actually open every day"
              body="Court rows × time columns. Drag to create slots. Click to edit. Booked games show the captain's avatar and team name. Collapsing the full pitch shows the quarters as a tiny inline 2×2 grid."
            />
            <Feature
              icon={<Wallet className="h-5 w-5" />}
              title="Money, not screenshots"
              body="Captains pay upfront via card or GCash. We hold the funds, take 5%, and push the rest to your GCash every Monday. You get a clean ledger and a payout receipt."
            />
            <Feature
              icon={<ShieldCheck className="h-5 w-5" />}
              title="Refunds you can defend"
              body="Standard tiered policy: ≥48h full refund, 24–48h half, under 24h none. Override per slot if a tournament needs stricter terms."
            />
          </div>
        </div>
      </section>

      {/* Pricing */}
      <section className="mx-auto w-full max-w-6xl px-6 py-20">
        <div className="grid gap-6 lg:grid-cols-[1fr_1.4fr] lg:items-center">
          <div>
            <h2 className="text-3xl font-medium tracking-tight">Simple pricing.</h2>
            <p className="mt-3 text-[15px] text-ink-dim">
              One number. No tiers. No setup fee.
            </p>
          </div>
          <div className="card-base p-8">
            <div className="flex items-baseline gap-3">
              <span className="font-mono text-6xl font-bold tracking-tight text-brand">5%</span>
              <span className="text-ink-dim">per paid booking</span>
            </div>
            <ul className="mt-6 grid gap-2 text-sm text-ink-dim">
              <li className="flex items-center gap-2">
                <Dot /> All payment processing included (cards, GCash, Maya)
              </li>
              <li className="flex items-center gap-2">
                <Dot /> Weekly automated payout to your GCash
              </li>
              <li className="flex items-center gap-2">
                <Dot /> Refunds handled inside the platform
              </li>
              <li className="flex items-center gap-2">
                <Dot /> Unlimited courts, unlimited slots
              </li>
            </ul>
          </div>
        </div>
      </section>

      {/* Footer */}
      <footer className="border-t border-line/50 py-10">
        <div className="mx-auto flex w-full max-w-6xl items-center justify-between px-6 text-xs text-ink-mute">
          <span>palaro.club · Manila · est. 2026</span>
          <span>Mga laro, sigurado.</span>
        </div>
      </footer>
    </div>
  );
}

function Feature({ icon, title, body }: { icon: React.ReactNode; title: string; body: string }) {
  return (
    <div className="card-base p-6">
      <div className="grid h-9 w-9 place-items-center rounded-md bg-brand/15 text-brand">
        {icon}
      </div>
      <h3 className="mt-4 text-base font-medium tracking-tight">{title}</h3>
      <p className="mt-2 text-[13px] leading-6 text-ink-dim">{body}</p>
    </div>
  );
}

function Dot() {
  return <span className="inline-block h-1 w-1 rounded-full bg-brand" />;
}

function CalendarHeroMock() {
  return (
    <div className="relative">
      <div className="absolute -inset-6 rounded-2xl bg-brand/10 blur-3xl" aria-hidden />
      <div className="relative card-base overflow-hidden">
        {/* Toolbar */}
        <div className="flex items-center justify-between border-b border-line/60 px-4 py-3 text-[12px] text-ink-dim">
          <div className="flex items-center gap-2">
            <span className="font-medium text-ink">Saturday</span>
            <span>· Apr 18</span>
          </div>
          <div className="flex items-center gap-1.5">
            <span className="rounded-md bg-bg-2 px-2 py-0.5 font-mono">Day</span>
            <span className="px-2 py-0.5">Week</span>
          </div>
        </div>
        {/* Grid */}
        <div className="grid grid-cols-[140px_1fr] divide-x divide-line/40 text-[12px]">
          <div className="space-y-2 p-3">
            <Row label="Full Pitch" hint="22" muted />
            <Row label="N Half" hint="14" />
            <Row label="S Half" hint="14" />
            <Row label="Q1" hint="7" />
            <Row label="Q2" hint="7" />
            <Row label="Q3" hint="7" />
            <Row label="Q4" hint="7" />
          </div>
          <div className="space-y-2 p-3">
            {/* Each row a strip of cells */}
            <Strip cells={['available', 'available', 'closed', 'closed']} />
            <Strip cells={['booked', 'booked', 'available', 'held']} />
            <Strip cells={['available', 'booked', 'available', 'available']} />
            <Strip cells={['booked', 'booked', 'available', 'held']} />
            <Strip cells={['booked', 'booked', 'available', 'available']} />
            <Strip cells={['available', 'booked', 'available', 'available']} />
            <Strip cells={['available', 'booked', 'available', 'available']} />
          </div>
        </div>
        <div className="flex items-center gap-3 border-t border-line/60 px-4 py-2.5 text-[11px] text-ink-mute">
          <Legend dot="bg-brand" label="Booked" />
          <Legend dot="bg-warn" label="Held" />
          <Legend dot="bg-bg-2 border border-line" label="Available" />
          <Legend dot="bg-line" label="Closed" />
        </div>
      </div>
    </div>
  );
}

function Row({ label, hint, muted }: { label: string; hint: string; muted?: boolean }) {
  return (
    <div className="flex h-8 items-center justify-between rounded-md px-2">
      <span className={muted ? 'text-ink-dim' : 'text-ink'}>{label}</span>
      <span className="font-mono text-[10px] text-ink-mute">{hint}</span>
    </div>
  );
}

function Strip({ cells }: { cells: ('available' | 'booked' | 'held' | 'closed')[] }) {
  const colors = {
    available: 'bg-bg-2 border border-dashed border-line/70',
    booked: 'bg-brand text-bg-0',
    held: 'bg-warn/20 border border-warn/50 text-warn',
    closed: 'bg-bg-2/40 text-ink-mute line-through',
  };
  return (
    <div className="grid h-8 grid-cols-4 gap-1.5">
      {cells.map((c, i) => (
        <div
          key={i}
          className={`grid place-items-center rounded-md text-[10px] font-mono ${colors[c]}`}
        >
          {c === 'booked' ? '₱2k' : c === 'held' ? '·' : ''}
        </div>
      ))}
    </div>
  );
}

function Legend({ dot, label }: { dot: string; label: string }) {
  return (
    <span className="inline-flex items-center gap-1.5">
      <span className={`h-2 w-2 rounded-sm ${dot}`} />
      {label}
    </span>
  );
}

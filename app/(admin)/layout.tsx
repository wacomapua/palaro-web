import { redirect } from 'next/navigation';
import Link from 'next/link';
import { CalendarDays, Home, ListTree, Receipt, Settings, Wallet } from 'lucide-react';
import { createClient } from '@/lib/supabase/server';
import { Button } from '@/components/ui/button';

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: venues } = await supabase
    .from('venues')
    .select('id, name, status')
    .eq('owner_id', user.id);
  const venue = venues?.[0];

  if (!venue) redirect('/onboarding/profile');

  return (
    <div className="grid min-h-screen grid-cols-[240px_1fr] bg-bg-0 text-ink">
      <aside className="border-r border-line/50 bg-bg-1/40">
        <div className="px-5 py-5">
          <div className="flex items-center gap-2">
            <span className="grid h-6 w-6 place-items-center rounded-md bg-brand text-bg-0 font-mono text-[11px] font-bold">
              P
            </span>
            <span className="text-sm font-medium tracking-tight">
              palaro<span className="text-ink-mute">·club</span>
            </span>
          </div>
        </div>
        <div className="px-3">
          <div className="rounded-md border border-line/60 bg-bg-1 p-3">
            <p className="text-[11px] uppercase tracking-wide text-ink-mute">Venue</p>
            <p className="mt-0.5 text-sm font-medium text-ink truncate">{venue.name}</p>
            <p className="mt-1 text-[11px] text-ink-dim capitalize">{venue.status.replace('_', ' ')}</p>
          </div>
        </div>
        <nav className="mt-4 px-3 space-y-0.5">
          <NavLink href="/dashboard" icon={<Home className="h-4 w-4" />}>Dashboard</NavLink>
          <NavLink href="/calendar" icon={<CalendarDays className="h-4 w-4" />}>Calendar</NavLink>
          <NavLink href="/slots" icon={<ListTree className="h-4 w-4" />}>Slots</NavLink>
          <NavLink href="/bookings" icon={<Receipt className="h-4 w-4" />}>Bookings</NavLink>
          <NavLink href="/payouts" icon={<Wallet className="h-4 w-4" />}>Payouts</NavLink>
          <NavLink href="/settings/venue" icon={<Settings className="h-4 w-4" />}>Settings</NavLink>
        </nav>
        <div className="absolute bottom-0 w-[240px] border-t border-line/50 p-3">
          <p className="text-[11px] text-ink-mute truncate">{user.email}</p>
          <form action="/auth/signout" method="post">
            <Button type="submit" variant="plain" size="sm" className="mt-2 w-full justify-start">
              Sign out
            </Button>
          </form>
        </div>
      </aside>
      <main className="overflow-x-hidden">{children}</main>
    </div>
  );
}

function NavLink({
  href,
  icon,
  children,
}: {
  href: string;
  icon: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <Link
      href={href}
      className="flex items-center gap-2 rounded-md px-3 py-1.5 text-[13px] text-ink-dim hover:bg-bg-2 hover:text-ink"
    >
      {icon}
      {children}
    </Link>
  );
}

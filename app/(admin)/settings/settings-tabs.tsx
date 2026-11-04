'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { cn } from '@/lib/cn';

const TABS = [
  { href: '/settings/venue', label: 'Venue' },
  { href: '/settings/courts', label: 'Courts' },
  { href: '/settings/schedule', label: 'Schedule' },
  { href: '/settings/refund-policy', label: 'Refund policy' },
  { href: '/settings/team', label: 'Team' },
];

export function SettingsTabs() {
  const pathname = usePathname();
  return (
    <nav className="flex gap-1 border-b border-line/50 px-8">
      {TABS.map((t) => {
        const active = pathname === t.href || pathname.startsWith(t.href + '/');
        return (
          <Link
            key={t.href}
            href={t.href}
            className={cn(
              'border-b-2 px-3 py-3 text-[13px] transition-colors -mb-px',
              active
                ? 'border-brand text-ink'
                : 'border-transparent text-ink-dim hover:text-ink',
            )}
          >
            {t.label}
          </Link>
        );
      })}
    </nav>
  );
}

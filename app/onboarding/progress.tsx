import Link from 'next/link';
import { Check } from 'lucide-react';
import { cn } from '@/lib/cn';

export type Step = { key: string; label: string; done: boolean };

export function OnboardingProgress({ steps }: { steps: Step[] }) {
  const firstUndone = steps.findIndex((s) => !s.done);
  const activeIdx = firstUndone === -1 ? steps.length - 1 : firstUndone;

  return (
    <ol className="flex items-center justify-center gap-2 text-xs">
      {steps.map((s, i) => {
        const active = i === activeIdx;
        return (
          <li key={s.key} className="flex items-center gap-2">
            <Link
              href={`/onboarding/${s.key}`}
              className={cn(
                'flex items-center gap-2 rounded-full px-3 py-1.5 transition-colors',
                active && 'bg-brand text-bg-0',
                !active && s.done && 'text-ink-dim hover:bg-bg-1',
                !active && !s.done && 'text-ink-mute',
              )}
            >
              <span
                className={cn(
                  'grid h-4 w-4 place-items-center rounded-full text-[10px] font-mono',
                  active && 'bg-bg-0 text-brand',
                  !active && s.done && 'bg-brand/20 text-brand',
                  !active && !s.done && 'border border-line text-ink-mute',
                )}
              >
                {s.done && !active ? <Check className="h-3 w-3" /> : i + 1}
              </span>
              {s.label}
            </Link>
            {i < steps.length - 1 && <span className="h-px w-4 bg-line" />}
          </li>
        );
      })}
    </ol>
  );
}

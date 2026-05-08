import * as React from 'react';
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '@/lib/cn';

const badgeVariants = cva(
  'inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-medium tracking-wide',
  {
    variants: {
      tone: {
        brand: 'bg-brand/15 text-brand-200',
        neutral: 'bg-bg-2 text-ink-dim',
        warn: 'bg-warn/15 text-warn',
        danger: 'bg-danger/15 text-danger',
        accent: 'bg-accent/15 text-accent',
      },
    },
    defaultVariants: { tone: 'neutral' },
  },
);

export interface BadgeProps
  extends React.HTMLAttributes<HTMLSpanElement>,
    VariantProps<typeof badgeVariants> {}

export function Badge({ className, tone, ...props }: BadgeProps) {
  return <span className={cn(badgeVariants({ tone, className }))} {...props} />;
}

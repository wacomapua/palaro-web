import * as React from 'react';
import { cn } from '@/lib/cn';

export const Input = React.forwardRef<
  HTMLInputElement,
  React.InputHTMLAttributes<HTMLInputElement>
>(({ className, type = 'text', ...props }, ref) => (
  <input
    ref={ref}
    type={type}
    className={cn(
      'h-10 w-full rounded-md border border-line/80 bg-bg-1 px-3 text-sm text-ink placeholder:text-ink-mute transition-colors focus:border-brand/60',
      className,
    )}
    {...props}
  />
));
Input.displayName = 'Input';

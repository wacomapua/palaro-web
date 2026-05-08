import type { Config } from 'tailwindcss';

const config: Config = {
  darkMode: ['class'],
  content: ['./app/**/*.{ts,tsx}', './components/**/*.{ts,tsx}', './lib/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        // Surface stack (dark-default; mirrors team-manager's mint accent).
        bg: {
          0: '#0B0F14',
          1: '#11161D',
          2: '#1A2029',
        },
        line: '#222A36',
        ink: {
          DEFAULT: '#E6EDF3',
          dim: '#9AA4B2',
          mute: '#5C6675',
        },
        brand: {
          DEFAULT: '#22D3A5',
          50: '#E6FBF4',
          100: '#C7F4E5',
          200: '#8FE8CB',
          300: '#5DDDB5',
          400: '#3AD6A8',
          500: '#22D3A5',
          600: '#1AA983',
          700: '#137E62',
          800: '#0D5341',
          900: '#062920',
        },
        accent: {
          DEFAULT: '#7C5CFF',
          500: '#7C5CFF',
        },
        warn: '#F4C152',
        danger: '#F26B6B',
        // shadcn semantic tokens
        background: '#0B0F14',
        foreground: '#E6EDF3',
        card: '#11161D',
        'card-foreground': '#E6EDF3',
        popover: '#11161D',
        'popover-foreground': '#E6EDF3',
        primary: '#22D3A5',
        'primary-foreground': '#062920',
        secondary: '#1A2029',
        'secondary-foreground': '#E6EDF3',
        muted: '#1A2029',
        'muted-foreground': '#9AA4B2',
        destructive: '#F26B6B',
        'destructive-foreground': '#1A0606',
        border: '#222A36',
        input: '#222A36',
        ring: '#22D3A5',
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', 'sans-serif'],
        mono: ['JetBrains Mono', 'ui-monospace', 'SFMono-Regular', 'monospace'],
      },
      fontSize: {
        // Linear-tight default body
        sm: ['13px', { lineHeight: '20px' }],
      },
      borderRadius: {
        lg: '10px',
        md: '8px',
        sm: '6px',
      },
      keyframes: {
        'pulse-brand': {
          '0%, 100%': { backgroundColor: 'rgba(34, 211, 165, 0.0)' },
          '50%': { backgroundColor: 'rgba(34, 211, 165, 0.18)' },
        },
        'slide-in-right': {
          '0%': { transform: 'translateX(100%)', opacity: '0' },
          '100%': { transform: 'translateX(0)', opacity: '1' },
        },
      },
      animation: {
        'pulse-brand': 'pulse-brand 800ms ease-out',
        'slide-in-right': 'slide-in-right 200ms ease-out',
      },
    },
  },
  plugins: [require('tailwindcss-animate')],
};

export default config;

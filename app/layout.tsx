import type { Metadata } from 'next';
import './globals.css';
import { ReactQueryProvider } from '@/lib/query-client';

export const metadata: Metadata = {
  title: 'palaro · club',
  description: 'List your courts. Get bookings. Get paid weekly. Palaro.club for venues.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="dark">
      <head>
        <link rel="preconnect" href="https://rsms.me/" />
        <link rel="stylesheet" href="https://rsms.me/inter/inter.css" />
        <link
          rel="stylesheet"
          href="https://cdn.jsdelivr.net/gh/JetBrains/JetBrainsMono/web/jetbrains-mono.css"
        />
      </head>
      <body>
        <ReactQueryProvider>{children}</ReactQueryProvider>
      </body>
    </html>
  );
}

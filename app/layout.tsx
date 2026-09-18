import type { Metadata, Viewport } from 'next';
import type { ReactNode } from 'react';
import './style.css';

export const metadata: Metadata = {
  title: 'Fantasy Market',
  description:
    'Mobile-first play-money prediction exchange for a private fantasy league.',
  applicationName: 'Fantasy Market',
};

export const viewport: Viewport = {
  themeColor: '#0F2B22',
  width: 'device-width',
  initialScale: 1,
  viewportFit: 'cover',
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}

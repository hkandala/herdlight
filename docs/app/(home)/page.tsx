import Link from 'next/link';
import { appName, docsRoute } from '@/lib/shared';

export default function HomePage() {
  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-6 px-6 py-24 text-center">
      <h1 className="text-4xl font-semibold">{appName}</h1>
      <p className="max-w-xl text-fd-muted-foreground">
        A native SwiftUI app for macOS, iPadOS and iOS that gives the{' '}
        <a href="https://github.com/herdrdev/herdr" className="underline">
          herdr
        </a>{' '}
        terminal multiplexer a modern interface: every machine at once, swipeable tabs, chat views
        for agents, floating panes and status pills. herdr stays the backend.
      </p>
      <Link
        href={docsRoute}
        className="rounded-full bg-fd-primary px-5 py-2 text-sm font-medium text-fd-primary-foreground"
      >
        Read the design
      </Link>
    </main>
  );
}

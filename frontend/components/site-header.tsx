import Link from "next/link";

export function SiteHeader() {
  return (
    <header className="sticky top-0 z-40 border-b border-border/70 bg-background/60 backdrop-blur-lg">
      <div className="mx-auto flex h-16 w-full max-w-5xl items-center gap-8 px-6 sm:px-8">
        <Link href="/" className="flex items-center gap-2">
          <span
            aria-hidden
            className="grid size-8 place-items-center rounded-full bg-linear-to-br from-primary to-chart-2 font-heading shadow-sm shadow-primary/30 text-[14px] leading-none font-semibold text-primary-foreground"
          >
            S
          </span>
          <span className="font-heading text-lg font-semibold">Spry</span>
        </Link>
        <nav className="flex items-center gap-1 text-sm">
          <Link
            href="/"
            aria-current="page"
            className="rounded-full bg-accent px-3.5 py-1.5 font-semibold text-accent-foreground"
          >
            Meetings
          </Link>
        </nav>
      </div>
    </header>
  );
}

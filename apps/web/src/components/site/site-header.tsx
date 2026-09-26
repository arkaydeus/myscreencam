import { DownloadButton, LogoMark } from "@/components/site/brand";
import { site } from "@/lib/site";

const nav = [
  { href: "#how", label: "How it works" },
  { href: "#features", label: "Features" },
  { href: "#performance", label: "Performance" },
  { href: "#faq", label: "FAQ" },
];

export function SiteHeader() {
  return (
    <header className="mx-auto flex w-full max-w-7xl items-center justify-between gap-6 px-5 py-5 sm:px-8">
      <a href="#top" className="flex items-center gap-2.5 rounded-md">
        <LogoMark />
        <span className="font-display text-lg font-extrabold tracking-tight">{site.name}</span>
      </a>
      <nav aria-label="Sections" className="hidden items-center gap-7 text-sm font-medium md:flex">
        {nav.map((item) => (
          <a
            key={item.href}
            href={item.href}
            className="rounded-sm text-muted-foreground transition-colors hover:text-foreground"
          >
            {item.label}
          </a>
        ))}
      </nav>
      <DownloadButton size="default" className="hidden sm:inline-flex" />
    </header>
  );
}

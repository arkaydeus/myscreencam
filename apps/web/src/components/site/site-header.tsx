import { DownloadButton, GitHubMark, LogoMark } from "@/components/site/brand";
import { wordmark } from "@/lib/fonts";
import { site } from "@/lib/site";
import { cn } from "@/lib/utils";

const nav = [
  { href: "#how", label: "How it works" },
  { href: "#features", label: "Features" },
  { href: "#performance", label: "Performance" },
  { href: "#faq", label: "FAQ" },
];

/** The product bar: translucent, pinned to the top, with the download always in reach. */
export function SiteHeader() {
  return (
    <header className="sticky top-0 z-50 border-b border-black/8 bg-white/80 backdrop-blur-xl backdrop-saturate-150">
      <div className="page-width flex h-12 items-center justify-between gap-3 sm:h-13 sm:gap-6">
        <a href="#top" className="flex shrink-0 items-center gap-2.5 rounded-md whitespace-nowrap">
          <LogoMark size={26} className="size-[22px] sm:size-[26px]" />
          <span className={cn(wordmark.className, "text-[17px] tracking-[-0.01em] sm:text-[21px]")}>
            {site.brand}
          </span>
        </a>
        <div className="flex shrink-0 items-center gap-7">
          <nav aria-label="Sections" className="hidden items-center gap-7 text-xs lg:flex">
            {nav.map((item) => (
              <a
                key={item.href}
                href={item.href}
                className="rounded-sm text-ink/80 transition-colors hover:text-ink"
              >
                {item.label}
              </a>
            ))}
          </nav>
          <a
            href={site.sourceUrl}
            aria-label="My Screen Cam on GitHub"
            className="-mx-1 hidden rounded-sm p-1 text-ink/80 transition-colors hover:text-ink sm:block"
          >
            <GitHubMark className="size-[18px]" />
          </a>
          <DownloadButton size="sm" />
        </div>
      </div>
    </header>
  );
}

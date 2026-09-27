import { DownloadButton, LogoMark } from "@/components/site/brand";
import { site } from "@/lib/site";

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
      <div className="page-width flex h-12 items-center justify-between gap-6 sm:h-13">
        <a href="#top" className="flex items-center gap-2.5 rounded-md">
          <LogoMark size={26} className="size-[22px] sm:size-[26px]" />
          <span className="text-[17px] font-semibold tracking-[-0.01em] sm:text-[21px]">
            {site.brand}
          </span>
        </a>
        <div className="flex items-center gap-7">
          <nav aria-label="Sections" className="hidden items-center gap-7 text-xs md:flex">
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
          <DownloadButton size="sm" />
        </div>
      </div>
    </header>
  );
}

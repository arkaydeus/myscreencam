import { ChevronRight } from "lucide-react";

import { DownloadButton, LogoMark } from "@/components/site/brand";
import { site } from "@/lib/site";

export function Closing() {
  return (
    <section id="download" className="scroll-mt-13 px-4 pb-18 sm:px-0 sm:pb-30">
      <div className="mx-auto max-w-[1160px] rounded-3xl p-5 canvas-paint sm:[width:calc(100%-2*var(--gutter))] sm:rounded-[36px] sm:p-[clamp(2rem,7vw,5.5rem)]">
        <div className="mx-auto flex max-w-[680px] flex-col items-center rounded-[18px] bg-white px-6 py-10 text-center shadow-[0_24px_60px_-12px_rgb(20_16_70/0.55)] sm:rounded-[28px] sm:px-14 sm:py-16">
          <LogoMark size={80} className="mb-5 size-16 sm:mb-6 sm:size-20" />
          <h2 className="text-[32px] leading-[1.12] font-semibold tracking-[-0.005em] text-balance sm:text-5xl sm:leading-[1.08]">
            Make your next recording look finished.
          </h2>
          <p className="mt-3.5 text-[17px] leading-[1.47] text-muted-foreground sm:mt-5 sm:text-[21px] sm:leading-[1.38]">
            Download MyScreenArt, record something, and see what the editor does with it.
          </p>
          <DownloadButton className="mt-7 sm:mt-9" />
          <p className="mt-3.5 text-xs text-muted-foreground sm:mt-4 sm:text-sm">
            {site.requirements}
          </p>
        </div>
      </div>
    </section>
  );
}

const footerLinks = [
  { href: site.releasesUrl, label: "Releases" },
  { href: "#faq", label: "FAQ" },
  { href: site.downloadUrl, label: "Download" },
];

/** Apple-style fine print: numbered footnotes, a breadcrumb, then links and the copyright line. */
export function SiteFooter() {
  return (
    <footer className="bg-paper text-xs leading-[1.33] text-muted-foreground">
      <div className="page-width-narrow pt-7 pb-10 sm:pt-9 sm:pb-12">
        <ol className="list-decimal border-b border-rule pb-4 pl-4 sm:pb-5">
          <li id="footnote-1">
            Measured on a MacBook Pro with M5 Max in September 2026. Your results depend on your
            Mac, your display and what’s on screen.
          </li>
        </ol>
        <div className="flex items-center gap-2 border-b border-rule py-4 text-ink">
          <LogoMark size={16} className="size-4" />
          <ChevronRight aria-hidden className="size-3 text-[#86868b]" strokeWidth={2} />
          <span>{site.name}</span>
        </div>
        <div className="flex flex-col-reverse gap-4 pt-4 sm:flex-row sm:items-center sm:justify-between">
          <p>
            Copyright © {new Date().getFullYear()} {site.name}. All rights reserved.
          </p>
          <nav aria-label="Footer" className="flex gap-5">
            {footerLinks.map((link) => (
              <a
                key={link.label}
                href={link.href}
                className="rounded-sm text-[#424245] hover:underline"
              >
                {link.label}
              </a>
            ))}
          </nav>
        </div>
      </div>
    </footer>
  );
}

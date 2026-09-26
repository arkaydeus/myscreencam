import { ChevronRight, Download } from "lucide-react";

import { site } from "@/lib/site";
import { cn } from "@/lib/utils";

/** Section headings share one size: 56 px on wide screens, 32 px on phones. */
export const sectionTitle =
  "text-[32px] leading-[1.125] font-semibold tracking-[-0.005em] text-balance sm:text-[56px] sm:leading-[1.07]";

/** The mark: a white "screen" framed on a painted canvas, like every MyScreenArt export. */
export function LogoMark({ className }: { className?: string }) {
  return (
    <span
      aria-hidden
      className={cn("relative inline-block size-7 rounded-[8px] canvas-paint", className)}
    >
      <span className="absolute inset-[22%] rounded-[3px] bg-white shadow-[0_2px_4px_rgb(20_16_70/0.35)]" />
    </span>
  );
}

/** The pill-shaped download link. `sm` is the compact one in the header. */
export function DownloadButton({
  className,
  size = "lg",
}: {
  className?: string;
  size?: "sm" | "lg";
}) {
  return (
    <a
      href={site.downloadUrl}
      className={cn(
        "inline-flex shrink-0 items-center justify-center gap-2 rounded-full bg-primary font-medium whitespace-nowrap text-primary-foreground transition-colors outline-none hover:bg-primary/90 focus-visible:ring-3 focus-visible:ring-ring/50",
        size === "lg" ? "h-12 px-6 text-[17px]" : "h-7 px-3 text-xs",
        className,
      )}
    >
      {size === "lg" ? (
        <>
          <Download aria-hidden className="size-[18px]" />
          Download for Mac
        </>
      ) : (
        "Download"
      )}
    </a>
  );
}

/** A text link with a trailing chevron, for "see more" style jumps. */
export function MoreLink({
  href,
  className,
  children,
}: {
  href: string;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <a
      href={href}
      className={cn(
        "inline-flex items-center gap-0.5 rounded-sm text-[17px] text-primary hover:underline",
        className,
      )}
    >
      {children}
      <ChevronRight aria-hidden className="size-4" strokeWidth={2.25} />
    </a>
  );
}

/** The webcam stand-in: a head and shoulders on a warm backdrop. */
export function Portrait() {
  return (
    <svg viewBox="0 0 100 100" className="block size-full">
      <circle cx="50" cy="42" r="17" fill="#6a3b2a" />
      <path d="M18 100c2-22 15-34 32-34s30 12 32 34z" fill="#2f46e8" />
    </svg>
  );
}

/** Links a measured figure to its footnote in the footer. */
export function FootnoteRef() {
  return (
    <sup className="ml-0.5 text-[0.6em] font-normal">
      <a href="#footnote-1" aria-label="Footnote 1" className="hover:underline">
        1
      </a>
    </sup>
  );
}

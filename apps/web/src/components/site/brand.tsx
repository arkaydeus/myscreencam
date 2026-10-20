import { ChevronRight, Download } from "lucide-react";
import Image from "next/image";

import appIcon from "@/assets/app-icon.png";
import { site } from "@/lib/site";
import { cn } from "@/lib/utils";

/** Section headings share one size: 56 px on wide screens, 32 px on phones. */
export const sectionTitle =
  "text-[32px] leading-[1.125] font-semibold tracking-[-0.005em] text-balance sm:text-[56px] sm:leading-[1.07]";

/**
 * The app icon. The image is the rounded shape alone, so it fills whatever square it's given.
 * `size` is the largest CSS size it's drawn at; next/image serves 1x and 2x files for it.
 */
export function LogoMark({ size, className }: { size: number; className?: string }) {
  return (
    <Image
      src={appIcon}
      alt=""
      aria-hidden
      width={size}
      height={size}
      className={cn("inline-block shrink-0", className)}
    />
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

/** GitHub's mark. lucide-react no longer ships brand icons. */
export function GitHubMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden className={cn("block", className)}>
      <path d="M12 .3a12 12 0 0 0-3.8 23.38c.6.12.83-.26.83-.57L9 21.07c-3.34.72-4.04-1.61-4.04-1.61-.55-1.39-1.34-1.76-1.34-1.76-1.08-.74.09-.73.09-.73 1.2.09 1.83 1.24 1.83 1.24 1.07 1.83 2.81 1.3 3.5 1 .1-.78.42-1.31.76-1.61-2.67-.3-5.47-1.33-5.47-5.93 0-1.31.47-2.38 1.24-3.22-.14-.3-.54-1.52.1-3.18 0 0 1-.32 3.3 1.23a11.5 11.5 0 0 1 6 0c2.28-1.55 3.29-1.23 3.29-1.23.64 1.66.24 2.88.12 3.18a4.65 4.65 0 0 1 1.23 3.22c0 4.61-2.8 5.63-5.48 5.92.42.36.81 1.1.81 2.22l-.01 3.29c0 .31.21.69.82.57A12 12 0 0 0 12 .3" />
    </svg>
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

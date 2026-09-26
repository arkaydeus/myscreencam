import { Download } from "lucide-react";

import { buttonVariants } from "@/components/ui/button";
import { site } from "@/lib/site";
import { cn } from "@/lib/utils";

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

export function DownloadButton({
  className,
  size = "lg",
}: {
  className?: string;
  size?: "default" | "lg";
}) {
  return (
    <a
      href={site.downloadUrl}
      className={cn(
        buttonVariants({ size: "lg" }),
        size === "lg" ? "h-12 gap-2 rounded-xl px-5 text-base" : "h-9 rounded-lg px-3.5",
        className,
      )}
    >
      <Download data-icon="inline-start" className={size === "lg" ? "size-5" : undefined} />
      Download for Mac
    </a>
  );
}

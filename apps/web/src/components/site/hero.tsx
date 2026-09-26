import { DownloadButton, MoreLink } from "@/components/site/brand";
import { CanvasDemo } from "@/components/site/canvas-demo";
import { site } from "@/lib/site";

export function Hero() {
  return (
    <section className="page-width pt-14 pb-18 text-center sm:pt-22 sm:pb-30">
      <p className="text-[19px] font-semibold sm:text-2xl">{site.name}</p>
      <h1 className="mx-auto mt-2.5 max-w-[980px] text-[40px] leading-[1.1] font-semibold tracking-[-0.015em] text-balance sm:text-[64px] lg:text-[80px] lg:leading-[1.05]">
        Screen recordings that look finished.
      </h1>
      <p className="mx-auto mt-5 max-w-[760px] text-[19px] leading-[1.42] text-pretty text-muted-foreground sm:mt-7 sm:text-2xl sm:leading-[1.34]">
        Record your Mac, and MyScreenArt adds the zooms, the painted background, the framed webcam
        and the tidy cursor. Then it exports in seconds on Apple’s hardware encoders.
      </p>
      <div className="mt-7 flex flex-col items-center gap-4 sm:mt-9 sm:flex-row sm:justify-center sm:gap-7">
        <DownloadButton />
        <MoreLink href="#how">See how it works</MoreLink>
      </div>
      <p className="mt-4 text-xs text-muted-foreground sm:text-sm">{site.requirements}</p>
      <CanvasDemo className="mx-auto mt-11 max-w-[1120px] text-left sm:mt-18" />
    </section>
  );
}

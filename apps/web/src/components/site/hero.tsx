import { DownloadButton } from "@/components/site/brand";
import { CanvasDemo } from "@/components/site/canvas-demo";
import { site } from "@/lib/site";

export function Hero() {
  return (
    <section className="mx-auto w-full max-w-7xl px-5 pt-10 pb-20 sm:px-8 sm:pt-16">
      <h1 className="max-w-[14ch] font-display text-[clamp(2.6rem,7.4vw,6.75rem)] leading-[0.94] font-extrabold tracking-[-0.035em] text-balance">
        Screen recordings that look finished.
      </h1>
      <div className="mt-8 grid gap-8 lg:grid-cols-[minmax(0,34rem)_1fr] lg:items-end">
        <p className="text-lg leading-relaxed text-muted-foreground sm:text-xl">
          Record your Mac and MyScreenArt adds the polish that takes hours by hand: zooms that
          follow your clicks, a painted background, a framed webcam and a tidy cursor. Then it
          exports in seconds on Apple’s hardware encoders.
        </p>
        <div className="flex flex-col items-start gap-3 lg:items-end">
          <DownloadButton />
          <p className="text-sm text-muted-foreground">{site.requirements}</p>
        </div>
      </div>
      <CanvasDemo className="mt-12 sm:mt-16" />
    </section>
  );
}

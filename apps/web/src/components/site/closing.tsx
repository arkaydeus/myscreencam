import { DownloadButton, LogoMark } from "@/components/site/brand";
import { site } from "@/lib/site";

export function Closing() {
  return (
    <section className="px-5 pb-6 sm:px-8">
      <div className="mx-auto w-full max-w-7xl rounded-[clamp(20px,3vw,40px)] p-[clamp(1.25rem,5vw,4.5rem)] canvas-paint">
        <div className="max-w-2xl rounded-2xl bg-white p-8 shadow-[0_24px_60px_-12px_rgb(20_16_70/0.55)] sm:p-12">
          <h2 className="font-display text-4xl leading-none font-extrabold tracking-[-0.03em] sm:text-5xl">
            Make your next recording look finished.
          </h2>
          <p className="mt-5 text-lg leading-relaxed text-muted-foreground">
            Download MyScreenArt, record something, and see what the editor does with it.
          </p>
          <div className="mt-8 flex flex-wrap items-center gap-x-5 gap-y-3">
            <DownloadButton />
            <span className="text-sm text-muted-foreground">{site.requirements}</span>
          </div>
        </div>
      </div>
    </section>
  );
}

export function SiteFooter() {
  return (
    <footer className="mx-auto flex w-full max-w-7xl flex-col gap-4 px-5 py-10 text-sm text-muted-foreground sm:flex-row sm:items-center sm:justify-between sm:px-8">
      <div className="flex items-center gap-2.5">
        <LogoMark className="size-5 rounded-[6px]" />
        <span>
          © {new Date().getFullYear()} {site.name}
        </span>
      </div>
      <nav aria-label="Footer" className="flex gap-6">
        <a href={site.releasesUrl} className="rounded-sm hover:text-foreground">
          Releases
        </a>
        <a href="#faq" className="rounded-sm hover:text-foreground">
          FAQ
        </a>
      </nav>
    </footer>
  );
}

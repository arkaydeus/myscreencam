import { FootnoteRef, MoreLink, Portrait, sectionTitle } from "@/components/site/brand";
import { HighlightsGallery } from "@/components/site/highlights-gallery";
import { cn } from "@/lib/utils";

/** Output shapes from the editor, drawn at roughly equal area. Heights are in container-width units. */
const aspects = [
  { label: "16:9", ratio: "16 / 9", height: 16.8, paint: "canvas-paint" },
  {
    label: "4:3",
    ratio: "4 / 3",
    height: 19.7,
    paint: "bg-[linear-gradient(140deg,var(--color-viridian),#0e5c6b)]",
  },
  { label: "1:1", ratio: "1 / 1", height: 19.7, paint: "bg-cadmium" },
  {
    label: "9:16",
    ratio: "9 / 16",
    height: 28,
    paint: "bg-[linear-gradient(160deg,var(--color-rose),#7b3fd6)]",
  },
];

const zoomModes = [
  {
    mode: "Manual",
    blocks: [
      [8, 30],
      [58, 80],
    ],
  },
  {
    mode: "On click",
    blocks: [
      [4, 18],
      [26, 44],
      [62, 74],
      [82, 96],
    ],
  },
  { mode: "Follow mouse", blocks: [[0, 100]] },
];

export function Highlights() {
  return (
    <section id="features" className="scroll-mt-13 bg-paper py-18 sm:pt-30 sm:pb-28">
      <div className="page-width flex items-end justify-between gap-6">
        <h2 className={sectionTitle}>Get the highlights.</h2>
        <MoreLink href="#how" className="mb-2.5 hidden sm:inline-flex">
          How it all fits together
        </MoreLink>
      </div>
      <HighlightsGallery>
        <Card
          eyebrow="Zoom"
          title="Zooms that follow every click."
          body="Add them by hand, make one for every click, or let the camera follow the mouse, with easing on every move."
        >
          <Visual>
            <div className="relative h-[180px] overflow-hidden rounded-2xl canvas-paint sm:h-[196px] sm:rounded-[18px]">
              <div className="absolute top-[16%] left-[14%] h-[110%] w-[96%] rounded-[10px] bg-white shadow-[0_16px_36px_-8px_rgb(20_16_70/0.5)]">
                <div className="absolute top-[22%] left-[16%] grid h-[30%] w-[56%] place-items-center rounded-xl bg-ultramarine text-[15px] font-medium text-white sm:text-[19px]">
                  Publish changes
                </div>
                <span className="absolute top-[37%] left-[44%] size-20 -translate-1/2 rounded-full border-[5px] border-cadmium sm:size-24 sm:border-[6px]" />
                {/* oxlint-disable-next-line nextjs/no-img-element -- tiny static SVG */}
                <img
                  src="/cursors/arrow.svg"
                  alt=""
                  className="absolute top-[34%] left-[43%] w-8 sm:w-10"
                />
              </div>
            </div>
            <div className="mt-4 hidden flex-col gap-2 text-xs font-semibold text-muted-foreground sm:flex">
              {zoomModes.map((row) => (
                <div key={row.mode} className="flex items-center gap-3">
                  <span className="w-21 shrink-0">{row.mode}</span>
                  <span className="relative h-[18px] flex-1 rounded-[5px] bg-[#ececf0]">
                    {row.blocks.map(([start, end]) => (
                      <span
                        key={start}
                        className="absolute inset-y-0 rounded-[5px] bg-cadmium"
                        style={{ left: `${start}%`, width: `${end - start}%` }}
                      />
                    ))}
                  </span>
                </div>
              ))}
            </div>
          </Visual>
        </Card>

        <Card
          eyebrow="Backgrounds"
          title="A painted canvas under every take."
          body="A colour, a gradient or your own image, with padding, rounded corners and a shadow. Shaped for wherever it’s going."
        >
          <Visual className="@container">
            <div className="flex items-end justify-between">
              {aspects.map((a) => (
                <div key={a.label} className="flex flex-col items-center gap-2.5">
                  <div
                    className={cn("relative rounded-[2cqw]", a.paint)}
                    style={{ aspectRatio: a.ratio, height: `${a.height}cqw` }}
                  >
                    <span className="absolute inset-[16%] rounded-[3px] bg-white shadow-[0_4px_10px_rgb(20_16_70/0.3)]" />
                  </div>
                  <span className="text-xs font-semibold text-muted-foreground tabular-nums">
                    {a.label}
                  </span>
                </div>
              ))}
            </div>
          </Visual>
        </Card>

        <Card
          eyebrow="Cursor"
          title="A cursor worth following."
          dark
          body="Keep your real cursor or switch to a clean set. Make it bigger, smooth out shaky movement and ring every click."
        >
          <Visual className="flex h-40 items-center justify-around sm:h-55">
            {/* oxlint-disable-next-line nextjs/no-img-element -- tiny static SVGs */}
            <img src="/cursors/arrow.svg" alt="" className="size-12 sm:size-15" />
            <span className="grid size-18 place-items-center rounded-full border-4 border-cadmium sm:size-22 sm:border-[5px]">
              {/* oxlint-disable-next-line nextjs/no-img-element -- tiny static SVGs */}
              <img src="/cursors/pointingHand.svg" alt="" className="size-12 sm:size-15" />
            </span>
            {/* oxlint-disable-next-line nextjs/no-img-element -- tiny static SVGs */}
            <img src="/cursors/iBeam.svg" alt="" className="size-12 sm:size-15" />
          </Visual>
        </Card>

        <Card
          eyebrow="Webcam"
          title="Your face, framed and in sync."
          body="A rounded, shadowed overlay you can drag anywhere, size and shape. Blur or remove the background behind you, and it stays in sync through every cut."
        >
          <Visual className="relative h-[180px] overflow-hidden rounded-2xl p-4 canvas-paint sm:h-55 sm:rounded-[18px]">
            <div className="h-full w-[78%] rounded-lg bg-white/95 shadow-[0_8px_24px_rgb(20_16_70/0.35)]" />
            <div className="absolute right-[6%] bottom-[10%] aspect-square w-[32%] overflow-hidden rounded-full border-4 border-white/85 bg-[linear-gradient(160deg,#ffd9a8,#f39a7a)] shadow-[0_10px_24px_rgb(20_16_70/0.45)]">
              <Portrait />
            </div>
          </Visual>
        </Card>

        <Card
          eyebrow="Export"
          title="Finished in seconds, not minutes."
          body="Encoding runs on your Mac’s media engine, which leaves the CPU free for everything else."
        >
          <div className="mt-auto">
            <p className="text-[96px] leading-none font-semibold tracking-[-0.03em] text-primary sm:text-[120px]">
              6×
            </p>
            <p className="mt-2 text-[19px] font-semibold sm:text-[21px]">
              faster than real time
              <FootnoteRef />
            </p>
            <p className="mt-2 hidden text-sm leading-[1.43] text-muted-foreground sm:block">
              A 3 min 47 s 4K recording with webcam and 16 zooms, exported to HEVC in 37 seconds.
            </p>
          </div>
        </Card>
      </HighlightsGallery>
    </section>
  );
}

/**
 * One card in the gallery. Its children are the illustration, pinned to the bottom of the card by
 * `Visual` (or `mt-auto`).
 */
function Card({
  eyebrow,
  title,
  body,
  dark,
  children,
}: {
  eyebrow: string;
  title: string;
  body: string;
  dark?: boolean;
  children: React.ReactNode;
}) {
  return (
    <li
      className={cn(
        "flex h-[520px] w-[300px] shrink-0 snap-start flex-col rounded-3xl px-6 pt-7 pb-6 sm:h-[640px] sm:w-[400px] sm:rounded-[28px] sm:px-8 sm:pt-9 sm:pb-8",
        dark ? "bg-black text-[#f5f5f7]" : "bg-white",
      )}
    >
      <p
        className={cn(
          "text-xs font-semibold sm:text-sm",
          dark ? "text-[#a1a1a6]" : "text-muted-foreground",
        )}
      >
        {eyebrow}
      </p>
      <h3 className="mt-1.5 text-2xl leading-[1.17] font-semibold sm:mt-2 sm:text-[28px] sm:leading-[1.14]">
        {title}
      </h3>
      <p
        className={cn(
          "mt-2.5 text-[15px] leading-[1.47] sm:mt-3 sm:text-[17px]",
          dark ? "text-[#a1a1a6]" : "text-muted-foreground",
        )}
      >
        {body}
      </p>
      {children}
    </li>
  );
}

function Visual({ className, children }: { className?: string; children: React.ReactNode }) {
  return (
    <div aria-hidden className={cn("mt-auto", className)}>
      {children}
    </div>
  );
}

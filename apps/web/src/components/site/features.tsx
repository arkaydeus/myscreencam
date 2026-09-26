import { AudioLines, EyeOff, Layers } from "lucide-react";

import { cn } from "@/lib/utils";

/** Output shapes from the editor, drawn at roughly equal area. Heights are in container-width units. */
const aspects = [
  { label: "16:9", ratio: "16 / 9", height: 15.3, paint: "canvas-paint" },
  {
    label: "4:3",
    ratio: "4 / 3",
    height: 17.9,
    paint: "bg-[linear-gradient(140deg,var(--color-viridian),#0e5c6b)]",
  },
  { label: "1:1", ratio: "1 / 1", height: 17.9, paint: "bg-cadmium" },
  {
    label: "9:16",
    ratio: "9 / 16",
    height: 25.5,
    paint: "bg-[linear-gradient(160deg,var(--color-rose),#7b3fd6)]",
  },
];

const cursors = [
  { src: "/cursors/arrow.svg", label: "Arrow" },
  { src: "/cursors/pointingHand.svg", label: "Pointing hand" },
  { src: "/cursors/iBeam.svg", label: "Text" },
];

const more = [
  {
    icon: EyeOff,
    title: "Blur",
    body: "Blur an email address, a token or a customer’s name for the part of the video where it’s showing.",
  },
  {
    icon: AudioLines,
    title: "Audio",
    body: "Microphone and system audio stay on separate tracks, each with its own level and waveform.",
  },
  {
    icon: Layers,
    title: "Presets",
    body: "Keep your background, cursor and zoom settings as a preset so every video matches.",
  },
];

export function Features() {
  return (
    <section id="features" className="scroll-mt-8 border-t border-rule">
      <div className="mx-auto w-full max-w-7xl px-5 py-20 sm:px-8 sm:py-28">
        <div className="grid gap-6 lg:grid-cols-[1fr_minmax(0,28rem)] lg:items-end">
          <h2 className="max-w-[16ch] font-display text-4xl leading-none font-extrabold tracking-[-0.03em] sm:text-5xl">
            The polish, without the afternoon in a video editor.
          </h2>
          <p className="text-lg leading-relaxed text-muted-foreground">
            Everything below is applied on top of your original footage. Change your mind next week
            and the untouched recording is still there.
          </p>
        </div>

        <div className="mt-14 grid gap-5 lg:grid-cols-12">
          <Panel className="lg:col-span-7" title="Backgrounds and framing">
            <p>
              Set your recording on a colour, a gradient or your own image, with padding, rounded
              corners and a shadow. Pick the shape for where it’s going: widescreen, 4:3, square or
              portrait for phones.
            </p>
            <div aria-hidden className="@container mt-auto">
              <div className="flex items-end gap-[4cqw]">
                {aspects.map((a) => (
                  <div key={a.label} className="flex flex-col items-center gap-2">
                    <div
                      className={cn("relative rounded-[1.4cqw]", a.paint)}
                      style={{ aspectRatio: a.ratio, height: `${a.height}cqw` }}
                    >
                      <span className="absolute inset-[16%] rounded-[4px] bg-white shadow-[0_4px_10px_rgb(20_16_70/0.3)]" />
                    </div>
                    <span className="text-xs font-semibold text-muted-foreground tabular-nums">
                      {a.label}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          </Panel>

          <Panel className="bg-ink text-white lg:col-span-5" title="Cursor" dark>
            <p>
              Keep your real cursor, switch to a clean stylised set, or pin a single shape. Make it
              bigger, smooth out shaky movement, and ring every click so viewers can follow along.
            </p>
            <div aria-hidden className="mt-auto flex h-40 items-center justify-around sm:h-48">
              {cursors.map((c, i) => (
                <div key={c.src} className="relative grid size-20 place-items-center">
                  {i === 1 && (
                    <span className="absolute inset-0 rounded-full border-4 border-cadmium" />
                  )}
                  {/* oxlint-disable-next-line nextjs/no-img-element -- tiny static SVGs */}
                  <img src={c.src} alt="" className="size-14" />
                </div>
              ))}
            </div>
          </Panel>

          <Panel className="lg:col-span-5" title="Zoom">
            <p>
              Add zooms by hand, make one for every click, or let the camera follow the mouse. A
              dead zone stops it chasing every small movement, and easing makes each move smooth.
            </p>
            <div aria-hidden className="mt-auto space-y-2.5">
              {[
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
              ].map((row) => (
                <div key={row.mode} className="flex items-center gap-3">
                  <span className="w-24 shrink-0 text-xs font-semibold text-muted-foreground">
                    {row.mode}
                  </span>
                  <div className="relative h-6 flex-1 rounded-md bg-secondary">
                    {row.blocks.map(([start, end]) => (
                      <span
                        key={start}
                        className="absolute inset-y-0 rounded-md bg-cadmium"
                        style={{ left: `${start}%`, width: `${end - start}%` }}
                      />
                    ))}
                  </div>
                </div>
              ))}
            </div>
          </Panel>

          <Panel className="lg:col-span-7" title="Webcam">
            <p>
              Your camera sits on top as a rounded, shadowed overlay. Drag it where you want it, set
              its size and shape, and it stays in sync through every cut.
            </p>
            <div
              aria-hidden
              className="relative mt-auto aspect-[16/7] overflow-hidden rounded-xl p-[4%] canvas-paint"
            >
              <div className="h-full w-[78%] rounded-md bg-white/95 shadow-[0_8px_24px_rgb(20_16_70/0.35)]" />
              <div className="absolute right-[5%] bottom-[10%] aspect-square w-[22%] overflow-hidden rounded-full border-4 border-white/85 bg-[linear-gradient(160deg,#ffd9a8,#f39a7a)] shadow-[0_10px_24px_rgb(20_16_70/0.45)]">
                <svg viewBox="0 0 100 100" className="size-full">
                  <circle cx="50" cy="42" r="17" fill="#6a3b2a" />
                  <path d="M18 100c2-22 15-34 32-34s30 12 32 34z" fill="#2f46e8" />
                </svg>
              </div>
            </div>
          </Panel>
        </div>

        <ul className="mt-12 grid gap-8 sm:grid-cols-3">
          {more.map((item) => (
            <li key={item.title} className="flex gap-4">
              <item.icon aria-hidden className="mt-0.5 size-6 shrink-0 text-ultramarine" />
              <div>
                <h3 className="font-semibold">{item.title}</h3>
                <p className="mt-1 leading-relaxed text-muted-foreground">{item.body}</p>
              </div>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}

function Panel({
  title,
  className,
  dark,
  children,
}: {
  title: string;
  className?: string;
  dark?: boolean;
  children: React.ReactNode;
}) {
  return (
    <article
      className={cn(
        "flex flex-col rounded-3xl bg-card p-7 sm:p-9",
        "[&>p]:mb-8 [&>p]:max-w-[52ch] [&>p]:leading-relaxed",
        dark ? "[&>p]:text-white/70" : "[&>p]:text-muted-foreground",
        className,
      )}
    >
      <h3 className="mb-3 font-display text-2xl font-extrabold tracking-tight">{title}</h3>
      {children}
    </article>
  );
}

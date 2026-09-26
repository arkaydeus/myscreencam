import { Check } from "lucide-react";

import { Portrait } from "@/components/site/brand";
import { cn } from "@/lib/utils";

/**
 * The hero: a looping, CSS-only mock of what MyScreenArt produces. A recording on a painted canvas, a
 * camera that zooms to the cursor's clicks, a webcam overlay, and the editor timeline driving it all.
 * Every animation shares the 12 s loop defined in globals.css, so the timeline's zoom blocks line up
 * with the preview. Positions are percentages of the recording so the targets stay under the cursor.
 */
export function CanvasDemo({ className }: { className?: string }) {
  return (
    <figure className={cn("w-full", className)}>
      <div className="relative aspect-[16/10] w-full overflow-hidden rounded-[clamp(18px,3.2vw,36px)] p-[5.5%] canvas-paint">
        <div className="@container relative h-full w-full overflow-hidden rounded-[1.6cqw] bg-white shadow-[0_2.5cqw_6cqw_-1cqw_rgb(20_16_70/0.55)]">
          <div className="absolute inset-0 demo-camera will-change-transform">
            <MockWindow />
            <span className="pointer-events-none absolute top-[73%] left-[76%] size-[9cqw] demo-click-publish rounded-full border-[0.6cqw] border-cadmium opacity-0" />
            <span className="pointer-events-none absolute top-[44%] left-[30%] size-[7cqw] demo-click-check rounded-full border-[0.6cqw] border-cadmium opacity-0" />
            {/* The arrow's tip sits at (4, 4) of its 32 px box. */}
            {/* oxlint-disable-next-line nextjs/no-img-element -- tiny static SVG, no optimisation needed */}
            <img
              src="/cursors/arrow.svg"
              alt=""
              className="absolute top-[30%] left-[46%] w-[3.4cqw] -translate-x-[12.5%] -translate-y-[12.5%] demo-cursor"
            />
          </div>
        </div>
        <WebcamBubble />
      </div>
      <Timeline />
      <figcaption className="sr-only">
        An animated example: a recording on a painted background zooms in as the cursor clicks
        “Publish changes”, zooms out, then zooms to a checklist item, while the editor timeline
        below shows the matching zoom blocks and clicks.
      </figcaption>
    </figure>
  );
}

function MockWindow() {
  const items = [
    { label: "Write the welcome email", top: "32%", done: true },
    { label: "Record the product tour", top: "44%", done: false },
    { label: "Review pricing page copy", top: "56%", done: true },
  ];

  return (
    <div aria-hidden className="absolute inset-0 text-[1.35cqw] text-[#23263f]">
      <div className="absolute inset-x-0 top-0 flex h-[7%] items-center gap-[0.8cqw] border-b border-[#e6e8ee] bg-[#f6f7f9] px-[1.6cqw]">
        <span className="size-[1.1cqw] rounded-full bg-[#ff5f57]" />
        <span className="size-[1.1cqw] rounded-full bg-[#febc2e]" />
        <span className="size-[1.1cqw] rounded-full bg-[#28c840]" />
        <span className="ml-[2cqw] text-[1.2cqw] text-[#6b6f86]">Launchpad</span>
      </div>

      <div className="absolute top-[7%] bottom-0 left-0 w-[22%] space-y-[1.4cqw] border-r border-[#e6e8ee] bg-[#f3f4f7] p-[1.8cqw] text-[1.25cqw] text-[#555a74]">
        <p className="font-semibold text-[#23263f]">Projects</p>
        <p className="-mx-[0.8cqw] rounded-[0.6cqw] bg-[#e3e6fb] px-[0.8cqw] py-[0.3cqw] text-ultramarine">
          Onboarding
        </p>
        <p>Billing revamp</p>
        <p>Mobile beta</p>
        <p>Help centre</p>
      </div>

      <div className="absolute top-[13%] left-[27%]">
        <p className="text-[2.6cqw] font-semibold tracking-tight">Onboarding launch</p>
        <p className="mt-[0.4cqw] text-[#6b6f86]">Due Friday</p>
      </div>

      {items.map((item) => (
        <div
          key={item.label}
          className="absolute left-[27%] flex h-[9%] w-[66%] -translate-y-1/2 items-center gap-[1.4cqw] rounded-[0.8cqw] border border-[#e6e8ee] px-[1.4cqw]"
          style={{ top: item.top }}
        >
          <span
            className={cn(
              "relative grid size-[2cqw] place-items-center rounded-[0.5cqw] border-[0.18cqw]",
              item.done ? "border-viridian bg-viridian text-white" : "border-[#b9bdcc]",
            )}
          >
            {item.done ? (
              <Check className="size-[1.4cqw]" strokeWidth={3} />
            ) : (
              <span className="absolute inset-[-0.18cqw] grid demo-checked place-items-center rounded-[0.5cqw] bg-viridian text-white opacity-0">
                <Check className="size-[1.4cqw]" strokeWidth={3} />
              </span>
            )}
          </span>
          <span>{item.label}</span>
        </div>
      ))}

      <div className="absolute top-[73%] left-[76%] grid h-[9%] w-[22%] -translate-1/2 place-items-center rounded-[0.9cqw] bg-ultramarine font-medium text-white">
        Publish changes
        <span className="absolute inset-0 flex demo-published items-center justify-center gap-[0.6cqw] rounded-[0.9cqw] bg-viridian opacity-0">
          <Check className="size-[1.5cqw]" strokeWidth={3} />
          Published
        </span>
      </div>
    </div>
  );
}

function WebcamBubble() {
  return (
    <div
      aria-hidden
      className="absolute top-[4%] right-[2.5%] aspect-square w-[15%] overflow-hidden rounded-full border-[0.35vw] border-white/85 bg-[linear-gradient(160deg,#ffd9a8,#f39a7a)] shadow-[0_1vw_2.5vw_-0.5vw_rgb(20_16_70/0.5)]"
    >
      <Portrait />
    </div>
  );
}

/** Loop-relative positions (percent of 12 s) shared with the keyframes in globals.css. */
const zoomBlocks = [
  { start: 14, end: 56, label: "1.85×" },
  { start: 73, end: 98, label: "1.7×" },
];
const clicks = [13.5, 72.5];

function Timeline() {
  const bars = Array.from({ length: 96 }, (_, i) => {
    const v = Math.abs(Math.sin(i * 0.9) * 0.55 + Math.sin(i * 0.23) * 0.45);
    return Math.round(18 + v * 72);
  });

  return (
    <div
      aria-hidden
      className="mt-2.5 rounded-[clamp(14px,2vw,22px)] bg-ink p-3 text-[11px] text-white/60 sm:mt-4 sm:p-4"
    >
      <div className="flex gap-3">
        <div className="hidden w-14 shrink-0 sm:block">
          <div className="h-4" />
          <div className="mt-1.5 flex h-9 items-center">Clip</div>
          <div className="mt-1.5 flex h-7 items-center">Zoom</div>
          <div className="mt-1.5 flex h-4 items-center">Clicks</div>
        </div>
        <div className="relative flex-1">
          <div className="flex h-4 justify-between font-medium tabular-nums">
            {[0, 3, 6, 9, 12].map((s) => (
              <span key={s}>0:{String(s).padStart(2, "0")}</span>
            ))}
          </div>

          <div className="mt-1.5 flex h-9 items-center gap-px overflow-hidden rounded-md bg-ultramarine/80 px-1.5">
            {bars.map((h, i) => (
              <span
                key={i}
                className="flex-1 rounded-full bg-white/45"
                style={{ height: `${h}%` }}
              />
            ))}
          </div>

          <div className="relative mt-1.5 h-7 rounded-md bg-white/5">
            {zoomBlocks.map((z) => (
              <span
                key={z.start}
                className="absolute inset-y-0 flex items-center rounded-md bg-cadmium px-2 font-semibold text-ink"
                style={{ left: `${z.start}%`, width: `${z.end - z.start}%` }}
              >
                {z.label}
              </span>
            ))}
          </div>

          <div className="relative mt-1.5 h-4">
            {clicks.map((c) => (
              <span
                key={c}
                className="absolute top-1/2 size-2.5 -translate-1/2 rounded-full border-2 border-cadmium"
                style={{ left: `${c}%` }}
              />
            ))}
          </div>

          <span className="absolute top-5 bottom-0 left-0 w-0.5 -translate-x-1/2 demo-playhead bg-white">
            <span className="absolute -top-1 left-1/2 size-2.5 -translate-x-1/2 rotate-45 rounded-[2px] bg-white" />
          </span>
        </div>
      </div>
    </div>
  );
}

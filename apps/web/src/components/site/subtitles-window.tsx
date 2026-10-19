import { ChevronDown, Plus, RefreshCw, Search, Volume2, Webcam, ZoomIn } from "lucide-react";

import {
  AppFrame,
  CaptionsBubbleIcon,
  ColorWell,
  CursorArrowIcon,
  DropHalfIcon,
  Panel,
  PopUp,
  RectangleInsetIcon,
  SliderTrack,
  Toggle,
} from "@/components/site/app-ui";
import { DemoRecording } from "@/components/site/demo-recording";
import { Transport } from "@/components/site/editor-demo";
import {
  CUT,
  LOOP,
  clock,
  micLevel,
  narration,
  peaks,
  waveformPath,
} from "@/components/site/editor-demo-script";
import { cn } from "@/lib/utils";

/*
 * The Annotate step: part of the editor with the Subtitles tab open (SubtitlesPanel.swift and
 * SubtitleStyleControls.swift), paused on a subtitle whose spoken word is highlighted. The cues are the
 * hero recording's narration (`narration` in editor-demo-script.ts).
 */

const WIDTH = 904;
// Leave room for all three cue cards, including CSS-pixel borders at mobile scales.
const HEIGHT = 624;
/** The left column (the preview, transport and timeline) and its timeline lane. */
const COLUMN = WIDTH - 16 - 8 - 320;
const LANE = COLUMN - 78 - 14;
export const ANNOTATE_TIME = 13.2;
const PLAYHEAD = ANNOTATE_TIME;
const x = (t: number) => (t / LOOP) * LANE;

/** The cue under the playhead, and the word being spoken in it. */
const active = narration.findIndex((cue) => PLAYHEAD >= cue.start && PLAYHEAD < cue.end);
export const ANNOTATE_WORD = "progress";
const spoken = ANNOTATE_WORD;

export function SubtitlesWindow({ className }: { className?: string }) {
  return (
    <AppFrame width={WIDTH} height={HEIGHT} className={className}>
      <div className="absolute inset-0 flex gap-8 ui-rounded-14 bg-ui-window p-8 shadow-[0_0_0_1px_rgb(255_255_255/0.1),0_2.5cqw_6cqw_-1cqw_rgb(4_6_20/0.55)]">
        <div className="flex w-[calc(var(--spacing)*560)] shrink-0 flex-col gap-8">
          <Panel stage className="flex-1">
            <Preview />
          </Panel>
          <Panel className="h-44 shrink-0">
            <Transport time={PLAYHEAD} playing={false} />
          </Panel>
          <Panel className="h-125 shrink-0">
            <SubtitleTimeline />
          </Panel>
        </div>
        <Panel className="w-320 shrink-0">
          <SubtitlesInspector />
        </Panel>
      </div>
    </AppFrame>
  );
}

/** The canvas with the subtitle burned in: bold white on a translucent box, the spoken word in yellow. */
function Preview() {
  const words = narration[active].text.split(" ");
  return (
    <div className="absolute top-1/2 left-0 aspect-video w-full -translate-y-1/2 overflow-hidden bg-[linear-gradient(45deg,#4f46e5,#db2777)]">
      <div className="@container absolute top-1/2 left-1/2 h-[88%] w-[79.2%] -translate-1/2 overflow-hidden ui-rounded-6 bg-white shadow-[0_1cqw_2.6cqw_-0.4cqw_rgb(10_8_40/0.6)]">
        <DemoRecording cursorLarge={false} time={PLAYHEAD} />
      </div>
      <p className="absolute inset-x-[10%] bottom-[7%] flex justify-center">
        <span className="max-w-full ui-rounded-5 bg-black/55 px-8 py-3 text-center ui-text-15.75 leading-[1.3] font-bold text-white [-webkit-text-stroke:calc(var(--spacing)*0.9)_black] [paint-order:stroke_fill]">
          {words.map((word, i) => (
            <span key={i}>
              {i > 0 && " "}
              {word === spoken ? (
                <span className="mx-[0.12em] inline-block scale-110 text-[#ffd60a]">{word}</span>
              ) : (
                word
              )}
            </span>
          ))}
        </span>
      </p>
    </div>
  );
}

/* The timeline, cut down to the rows that matter here: the screen, the narration and its subtitles. */

const rows = [
  { title: "Screen", top: 24, height: 34 },
  { title: "Mic", top: 61, height: 30 },
  { title: "Subtitles", top: 94, height: 22 },
] as const;

function SubtitleTimeline() {
  const [screen, mic, subtitles] = rows;
  return (
    <div className="relative h-full ui-text-11">
      <div className="absolute inset-x-0 top-0 h-24 border-b border-white/8" />
      {rows.map((row) => (
        <div
          key={row.title}
          className="absolute inset-x-0 flex items-center bg-ui-row pl-10 font-medium text-ui-fg-2"
          style={{
            top: `calc(var(--spacing) * ${row.top})`,
            height: `calc(var(--spacing) * ${row.height})`,
          }}
        >
          {row.title}
        </div>
      ))}
      <div className="absolute inset-y-0 right-14 left-78">
        <svg viewBox={`0 0 ${LANE} 125`} className="absolute inset-0 size-full overflow-visible">
          {Array.from({ length: LOOP + 1 }, (_, s) => (
            <line
              key={s}
              x1={x(s)}
              x2={x(s)}
              y1={24}
              y2={24 - (s % 5 === 0 ? 9 : 4)}
              stroke="#66718f"
            />
          ))}
          {[0, 5, 10, 15, 20].map((s) => (
            <text key={s} x={x(s) + 3} y={12} fontSize={10} fill="#9aa5c2">
              0:{String(s).padStart(2, "0")}
            </text>
          ))}
          {[
            [0, CUT],
            [CUT, LOOP],
          ].map(([a, b]) => (
            <rect
              key={a}
              x={x(a) + 1}
              y={screen.top + 2}
              width={x(b) - x(a) - 2}
              height={screen.height - 4}
              rx={6}
              fill="rgb(61 220 151 / 0.28)"
              stroke="rgb(61 220 151 / 0.6)"
            />
          ))}
          <path
            d={waveformPath(peaks(Math.floor(LANE / 2), micLevel), mic.top, mic.height)}
            fill="rgb(124 184 255 / 0.75)"
          />
        </svg>
        {narration.map((cue) => (
          <span
            key={cue.start}
            className="absolute truncate ui-rounded-4 border border-ui-subtitle bg-ui-subtitle/30 pl-3 ui-text-10 leading-[calc(var(--spacing)*14)]"
            style={{
              left: `${(cue.start / LOOP) * 100}%`,
              width: `${((cue.end - cue.start) / LOOP) * 100}%`,
              top: `calc(var(--spacing) * ${subtitles.top + 3})`,
              height: `calc(var(--spacing) * ${subtitles.height - 6})`,
            }}
          >
            {cue.text}
          </span>
        ))}
        <span
          className="absolute inset-y-0 w-2 -translate-x-1/2 bg-ui-playhead"
          style={{ left: `${(PLAYHEAD / LOOP) * 100}%` }}
        >
          <svg viewBox="0 0 12 14" className="absolute top-0 left-1/2 h-14 w-12 -translate-x-1/2">
            <path d="M0 0h12v8l-6 6-6-6z" fill="#ff5c8a" />
          </svg>
        </span>
      </div>
    </div>
  );
}

/* The inspector on its Subtitles tab. */

const tabIcons = [
  <ZoomIn key="zoom" className="size-16" strokeWidth={1.8} />,
  <Webcam key="webcam" className="size-16" strokeWidth={1.8} />,
  <Volume2 key="audio" className="size-16" strokeWidth={1.8} />,
  <DropHalfIcon key="blur" className="size-16" />,
  <CursorArrowIcon key="cursor" className="size-17" />,
  <RectangleInsetIcon key="background" className="size-17" />,
  <CaptionsBubbleIcon key="subtitles" className="size-16" />,
];

function SubtitlesInspector() {
  return (
    <div className="flex h-full flex-col">
      <div className="px-14 pt-14">
        <div className="flex gap-2 ui-rounded-8 border border-white/9 bg-white/6 p-3">
          {tabIcons.map((icon, i) => (
            <span
              key={icon.key}
              className={cn(
                "grid h-30 flex-1 place-items-center ui-rounded-5",
                i === tabIcons.length - 1
                  ? "bg-ui-accent text-ui-on-accent shadow-[0_3px_7px_rgb(61_220_151/0.35)]"
                  : "text-ui-fg-2",
              )}
            >
              {icon}
            </span>
          ))}
        </div>
        <div className="mt-14 flex items-baseline justify-between">
          <span className="ui-text-20 font-bold">Subtitles</span>
          <span className="ui-text-11.5 text-ui-fg-3">{narration.length} subtitles</span>
        </div>
      </div>

      <div className="relative min-h-0 flex-1 space-y-10 overflow-hidden px-14 pt-10 ui-text-13">
        <div className="flex items-center gap-8">
          <div className="leading-[1.3]">
            <p className="ui-text-12">{narration.length} subtitles</p>
            <p className="ui-text-10 text-ui-fg-2">Parakeet Ultra</p>
          </div>
          <RefreshCw className="ml-auto size-14 text-ui-fg-2" strokeWidth={2} />
        </div>

        <div className="flex items-center gap-6 font-semibold">
          <ChevronDown className="size-11 text-ui-fg-2" strokeWidth={2.6} />
          Style & Position
          <Toggle on className="ml-auto" />
        </div>
        <div className="flex items-center justify-between">
          Font
          <PopUp value="System" className="w-150 justify-between" />
        </div>
        <div className="flex items-center gap-8">
          {["B", "I", "Uppercase"].map((label) => (
            <span
              key={label}
              className={cn(
                "grid h-22 min-w-28 place-items-center ui-rounded-6 border border-white/9 px-8 ui-text-12",
                label === "B" ? "bg-ui-accent/25 font-bold" : "bg-white/6",
                label === "I" && "italic",
              )}
            >
              {label}
            </span>
          ))}
          <span className="ml-auto">Text</span>
          <ColorWell color="#ffffff" />
        </div>
        <div className="flex items-center gap-8">
          Highlight spoken word
          <Toggle on />
          <span className="ml-auto">
            <ColorWell color="#ffd60a" />
          </span>
        </div>
        <Slider title="Grow" value="+10%" position={0.1 / 0.5} />
        <Slider title="Size" value="5.0%" position={0.03 / 0.13} />

        <div className="h-px bg-white/8" />

        <div className="flex items-center gap-8">
          <span className="flex h-24 flex-1 items-center gap-6 ui-rounded-6 bg-white/6 px-7 text-ui-fg-3">
            <Search className="size-12" strokeWidth={2.2} />
            Search subtitles
          </span>
          <Plus className="size-14 text-ui-fg-2" strokeWidth={2} />
        </div>

        <div className="space-y-4">
          {narration.slice(active - 1, active + 2).map((cue, i) => {
            const isActive = i === 1;
            return (
              <div
                key={cue.start}
                className={cn(
                  "space-y-6 ui-rounded-7 p-8",
                  isActive ? "bg-ui-accent/7" : "bg-white/3",
                )}
              >
                <p
                  className={cn(
                    "font-mono ui-text-10",
                    isActive ? "text-ui-accent" : "text-ui-fg-2",
                  )}
                >
                  {clock(cue.start)} – {clock(cue.end)}
                </p>
                <p className="ui-text-12.5 leading-[1.3]">{cue.text}</p>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

/** `ValueSlider` outside a form: title and value, then a full-width slider. */
function Slider({ title, value, position }: { title: string; value: string; position: number }) {
  return (
    <div>
      <div className="flex justify-between ui-text-11.5">
        <span>{title}</span>
        <span className="text-ui-fg-2 tabular-nums">{value}</span>
      </div>
      <SliderTrack value={position} className="mt-2" />
    </div>
  );
}

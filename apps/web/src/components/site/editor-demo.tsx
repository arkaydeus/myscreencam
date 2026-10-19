"use client";

import {
  ChevronLeft,
  Pause,
  Play,
  Plus,
  Scissors,
  Share,
  SlidersHorizontal,
  SquareArrowDownLeft,
  SquareArrowDownRight,
  SquareArrowUpLeft,
  SquareArrowUpRight,
  SquareDashed,
  SquareMinus,
  Trash2,
  Volume2,
  Webcam,
  ZoomIn,
  ZoomOut,
} from "lucide-react";
import { type CSSProperties, type ReactNode, useEffect, useRef, useState } from "react";

import {
  AppButton,
  AppFrame,
  CaptionsBubbleIcon,
  ColorWell,
  CursorArrowIcon,
  DropHalfIcon,
  FormRow,
  FormSection,
  MacWindow,
  Panel,
  PopUp,
  RectangleInsetIcon,
  ResetCutsIcon,
  ScrollThumb,
  Segmented,
  SkipIcon,
  SliderRow,
  Toggle,
} from "@/components/site/app-ui";
import { Portrait } from "@/components/site/brand";
import { DemoRecording } from "@/components/site/demo-recording";
import {
  CUT,
  LOOP,
  REST,
  type Dragged,
  type Flipped,
  type Step,
  type Tab,
  blurMask,
  clicks,
  clock,
  cursorAt,
  dragged,
  easeInOut,
  flipped,
  micLevel,
  noise,
  peaks,
  recordingAt,
  script,
  talking,
  waveformPath,
  zoomEnd,
  zooms,
} from "@/components/site/editor-demo-script";
import { cn } from "@/lib/utils";

/*
 * The hero: My Screen Cam's editor, drawn in HTML at its real 1280 × 800 pt layout (EditorView.swift and
 * friends), playing a recording while a pointer works the inspector. Everything runs off one clock
 * (editor-demo-script.ts): a requestAnimationFrame loop writes the per-frame parts (camera, cursor, playhead,
 * time, meters) straight to the DOM, and React state only changes when the pointer clicks something.
 */

const WIDTH = 1280;
const HEIGHT = 800;
/** Where the pointer waits, over the inspector. */
const REST_POINT = { x: 1118, y: 610 } as const;

type Ui = {
  tab: Tab;
  selectedZoom: string | null;
  scrolled: boolean;
} & { [K in Flipped]: (typeof flipped)[K][number] };

const initialUi: Ui = {
  tab: "zoom",
  selectedZoom: null,
  scrolled: false,
  webcamAspect: "Wide",
  webcamShape: "Rounded",
  cursorSize: "M",
};

type Values = Record<Dragged, number>;

const initialValues: Values = {
  zoomScale: dragged.zoomScale.from,
  padding: dragged.padding.from,
  radius: dragged.radius.from,
  gain: dragged.gain.from,
};

const fraction = (key: Dragged, v: number) =>
  (v - dragged[key].min) / (dragged[key].max - dragged[key].min);

const format: Record<Dragged, (v: number) => string> = {
  zoomScale: (v) => `${v.toFixed(2)}×`,
  padding: (v) => `${Math.round(v * 100)}%`,
  radius: (v) => `${Math.round(v * 100)}%`,
  gain: (v) => `${v >= 0 ? "+" : "−"}${Math.abs(v).toFixed(1)} dB`,
};

/** Custom properties the sliders and the preview read; the loop rewrites them as values are dragged. */
const cssVar: Record<Dragged, string> = {
  zoomScale: "--zoom-scale",
  padding: "--pad",
  radius: "--rad",
  gain: "--gain",
};

const initialVars = Object.fromEntries(
  (Object.keys(initialValues) as Dragged[]).map((key) => [
    cssVar[key],
    fraction(key, initialValues[key]),
  ]),
) as CSSProperties;

/** `--pad` and `--rad` hold slider positions; these turn them back into the edit's fractions. */
const padding = `(var(--pad) * ${dragged.padding.max})`;
const radius = `(var(--rad) * ${dragged.radius.max})`;

export function EditorDemo({ className }: { className?: string }) {
  const stage = useRef<HTMLDivElement>(null);
  const values = useRef<Values>({ ...initialValues });
  const [ui, setUi] = useState<Ui>(initialUi);

  useEffect(() => {
    const root = stage.current;
    if (!root) return;
    return runDemo(root, values.current, setUi);
  }, []);

  const text = (key: Dragged) => format[key](values.current[key]);

  return (
    <figure className={className}>
      <AppFrame width={WIDTH} height={HEIGHT}>
        <div ref={stage} aria-hidden className="absolute inset-0 select-none" style={initialVars}>
          <MacWindow title="Launchpad onboarding tour">
            <Header />
            <div className="absolute inset-x-8 top-52 bottom-8 flex gap-8">
              <div className="flex min-w-0 flex-1 flex-col gap-8">
                <Panel stage className="flex-1">
                  <Preview ui={ui} />
                </Panel>
                <Panel className="h-44 shrink-0">
                  <Transport />
                </Panel>
                <Panel className="h-233 shrink-0">
                  <Timeline selectedZoom={ui.selectedZoom} />
                </Panel>
              </div>
              <Panel className="w-320 shrink-0">
                <Inspector ui={ui} text={text} />
              </Panel>
            </div>
          </MacWindow>
          <Pointer />
        </div>
      </AppFrame>
      <figcaption className="sr-only">
        The My Screen Cam editor playing a recording of a project app. The preview zooms in on each
        click while the timeline shows the matching zoom blocks, waveforms and clicks. In the
        inspector, the pointer changes a zoom’s scale, the background padding and corners, the
        webcam’s shape and position, the cursor size and the microphone gain.
      </figcaption>
    </figure>
  );
}

/* Layout */

function Header() {
  return (
    <div className="flex h-52 items-center gap-10 px-12">
      <AppButton icon={<ChevronLeft className="size-15" strokeWidth={2.2} />}>Library</AppButton>
      <AppButton icon={<SlidersHorizontal className="size-14" strokeWidth={2} />}>
        Presets
      </AppButton>
      <span className="h-20 w-px bg-white/9" />
      <div className="leading-[1.2]">
        <p className="ui-text-13 font-semibold">Launchpad onboarding tour</p>
        <p className="ui-text-10 text-ui-fg-2">18 Oct 2026 at 23:06</p>
      </div>
      <span className="flex-1" />
      <AppButton kind="destructive" icon={<Trash2 className="size-14" strokeWidth={2} />}>
        Delete
      </AppButton>
      <AppButton kind="primary" icon={<Share className="size-14" strokeWidth={2.2} />}>
        Export
      </AppButton>
    </div>
  );
}

/** The canvas: the edit's gradient background, the recording inset by the padding, and the webcam. */
function Preview({ ui }: { ui: Ui }) {
  // The webcam is 20% of the canvas wide, 3% in from the bottom-left corner. Its corner radius is a
  // fraction of its shorter side: 20% of the canvas height when wide, 35.6% when square.
  const square = ui.webcamAspect === "Square";
  const shorter = (square ? 0.2 * (16 / 9) : 0.2) * 413;
  const webcamRadius = (ui.webcamShape === "Circle" ? 0.5 : 0.1) * shorter;
  return (
    <div className="absolute inset-y-0 left-1/2 aspect-video -translate-x-1/2 overflow-hidden bg-[linear-gradient(45deg,#4f46e5,#db2777)]">
      <div
        className="@container absolute top-1/2 left-1/2 -translate-1/2 overflow-hidden bg-white shadow-[0_1cqw_2.6cqw_-0.4cqw_rgb(10_8_40/0.6)]"
        style={{
          width: `calc(90% * (1 - 2 * ${padding}))`,
          height: `calc(100% * (1 - 2 * ${padding}))`,
          borderRadius: `calc(var(--spacing) * 413 * ${radius} * (1 - 2 * ${padding}))`,
        }}
      >
        <DemoRecording cursorLarge={ui.cursorSize === "L"} />
      </div>
      <div
        className="absolute bottom-[5.33%] left-[3%] w-[20%] overflow-hidden bg-[linear-gradient(160deg,#ffd9a8,#f39a7a)] shadow-[0_0.6cqw_1.6cqw_-0.3cqw_rgb(10_8_40/0.55)] transition-[height,border-radius] duration-300 ease-out"
        style={{
          height: square ? "35.56%" : "20%",
          borderRadius: `calc(var(--spacing) * ${webcamRadius})`,
        }}
      >
        <Portrait />
      </div>
    </div>
  );
}

export function Transport({ time = 0, playing = true }: { time?: number; playing?: boolean }) {
  const icon = "grid size-30 place-items-center";
  return (
    <div className="flex h-full items-center gap-14 px-12">
      <span className="flex h-26 w-170 items-center ui-rounded-6 border border-white/9 bg-white/6 px-10 font-mono ui-text-12 whitespace-nowrap">
        <span data-el="time">{clock(time)}</span>
        <span className="text-ui-fg-2">&nbsp;/ {clock(LOOP)}</span>
      </span>
      <span className="flex items-center gap-4">
        <span className={icon}>
          <SkipIcon className="size-19" />
        </span>
        <span className="grid size-34 place-items-center ui-rounded-6 bg-ui-accent text-ui-on-accent shadow-[0_0_6px_rgb(61_220_151/0.3)]">
          {playing ? (
            <Pause className="size-15" fill="currentColor" strokeWidth={0} />
          ) : (
            <Play className="ml-2 size-15" fill="currentColor" strokeWidth={0} />
          )}
        </span>
        <span className={icon}>
          <SkipIcon forward className="size-19" />
        </span>
      </span>
      <span className="h-18 w-px bg-white/9" />
      <span className="flex items-center gap-6">
        <span className={icon}>
          <Scissors className="size-16" strokeWidth={1.8} />
        </span>
        <span className={cn(icon, "text-ui-fg-3")}>
          <SquareMinus className="size-16" strokeWidth={1.8} />
        </span>
        <span className={icon}>
          <ResetCutsIcon className="size-17" />
        </span>
      </span>
      <span className="flex-1" />
      <span className="flex items-center gap-4 ui-text-13">
        <span className={icon}>
          <ZoomOut className="size-16" strokeWidth={1.8} />
        </span>
        <span className="px-4 tabular-nums">100%</span>
        <span className={icon}>
          <ZoomIn className="size-16" strokeWidth={1.8} />
        </span>
      </span>
    </div>
  );
}

/** The transport and timeline alone, still, for the Edit step: paused partway through, a zoom selected. */
export function TimelineCloseUp() {
  return (
    <>
      <Panel className="h-44 shrink-0">
        <Transport time={10.4} playing={false} />
      </Panel>
      <Panel className="h-233 shrink-0">
        <Timeline selectedZoom="z2" playhead={10.4} />
      </Panel>
    </>
  );
}

/* Timeline (TimelineView.swift): a 78 pt gutter of row titles, then the rows in edited time. */

const rows = [
  { title: "Screen", height: 34 },
  { title: "Webcam", height: 22 },
  { title: "System", height: 30 },
  { title: "Mic", height: 30 },
  { title: "Zoom", height: 28 },
  { title: "Blur", height: 22 },
  { title: "Clicks", height: 16 },
] as const;

type RowTitle = (typeof rows)[number]["title"];

const RULER = 24;
const ROW_GAP = 3;
/** Width of the lane right of the gutter: the 936 pt column, less the gutter and trailing pad. */
const LANE = 936 - 78 - 14;
const rowTop = (() => {
  const tops = {} as Record<RowTitle, number>;
  let y = RULER;
  for (const row of rows) {
    tops[row.title] = y;
    y += row.height + ROW_GAP;
  }
  return tops;
})();
const rowHeight = (title: RowTitle) => rows.find((r) => r.title === title)!.height;
const x = (t: number) => (t / LOOP) * LANE;

const columns = (level: (t: number, i: number) => number) => peaks(Math.floor(LANE / 2), level);
const micPeaks = columns(micLevel);
const systemPeaks = columns((t, i) => {
  const near = clicks.find((c) => t >= c && t < c + 0.35);
  return near === undefined ? 0 : (0.55 - (t - near)) * (0.6 + 0.4 * noise(i));
});

function Timeline({
  selectedZoom,
  playhead = 0,
}: {
  selectedZoom: string | null;
  playhead?: number;
}) {
  const screen = rowTop.Screen;
  const zoomTop = rowTop.Zoom + 3;
  const zoomBottom = rowTop.Zoom + rowHeight("Zoom") - 3;
  const pieces = [
    [0, CUT],
    [CUT, LOOP],
  ] as const;

  return (
    <div className="relative h-full ui-text-11">
      <div className="absolute inset-x-0 top-0 h-24 border-b border-white/8" />
      {rows.map((row) => (
        <div
          key={row.title}
          className="absolute inset-x-0 flex items-center bg-ui-row pl-10 font-medium text-ui-fg-2"
          style={{
            top: `calc(var(--spacing) * ${rowTop[row.title]})`,
            height: `calc(var(--spacing) * ${row.height})`,
          }}
        >
          {row.title}
        </div>
      ))}

      <div className="absolute inset-y-0 right-14 left-78">
        <svg viewBox={`0 0 ${LANE} 233`} className="absolute inset-0 size-full overflow-visible">
          {/* Ruler: a major tick and label every 5 s, minor ticks every second. */}
          {Array.from({ length: LOOP + 1 }, (_, s) => (
            <line
              key={s}
              x1={x(s)}
              x2={x(s)}
              y1={RULER}
              y2={RULER - (s % 5 === 0 ? 9 : 4)}
              stroke="#66718f"
            />
          ))}
          {[0, 5, 10, 15, 20].map((s) => (
            <text key={s} x={x(s) + 3} y={12} fontSize={10} fill="#9aa5c2">
              0:{String(s).padStart(2, "0")}
            </text>
          ))}

          {/* Screen: the two segments either side of the cut, with trim handles at the ends. */}
          {pieces.map(([a, b]) => (
            <rect
              key={a}
              x={x(a) + 1}
              y={screen + 2}
              width={x(b) - x(a) - 2}
              height={rowHeight("Screen") - 4}
              rx={6}
              fill="rgb(61 220 151 / 0.28)"
              stroke="rgb(61 220 151 / 0.6)"
            />
          ))}
          {[x(0) + 1, x(LOOP) - 7].map((hx) => (
            <rect
              key={hx}
              x={hx}
              y={screen + 6}
              width={6}
              height={rowHeight("Screen") - 12}
              rx={2}
              fill="rgb(255 255 255 / 0.9)"
              stroke="#3ddc97"
            />
          ))}

          {pieces.map(([a, b]) => (
            <rect
              key={a}
              x={x(a) + 1}
              y={rowTop.Webcam + 3}
              width={x(b) - x(a) - 2}
              height={rowHeight("Webcam") - 6}
              rx={5}
              fill="rgb(91 124 255 / 0.55)"
            />
          ))}

          <path
            d={waveformPath(systemPeaks, rowTop.System, rowHeight("System"))}
            fill="rgb(177 140 255 / 0.75)"
          />
          <path
            d={waveformPath(micPeaks, rowTop.Mic, rowHeight("Mic"))}
            fill="rgb(124 184 255 / 0.75)"
          />

          {zooms.map((z) => {
            const selected = z.id === selectedZoom;
            const x0 = x(z.start);
            const x1 = x(z.start + z.easeIn);
            const x2 = x(z.start + z.easeIn + z.hold);
            const x3 = x(zoomEnd(z));
            return (
              <path
                key={z.id}
                d={`M${x0} ${zoomBottom}L${x1} ${zoomTop}L${x2} ${zoomTop}L${x3} ${zoomBottom}Z`}
                fill={selected ? "rgb(255 178 91 / 0.85)" : "rgb(255 178 91 / 0.5)"}
                stroke={selected ? "#fff" : "#ffb25b"}
                strokeWidth={1.5}
              />
            );
          })}

          <rect
            x={x(blurMask.start)}
            y={rowTop.Blur + 3}
            width={x(blurMask.end) - x(blurMask.start)}
            height={rowHeight("Blur") - 6}
            rx={5}
            fill="rgb(255 111 174 / 0.35)"
            stroke="#ff6fae"
          />

          {clicks.map((c) => (
            <circle
              key={c}
              cx={x(c)}
              cy={rowTop.Clicks + rowHeight("Clicks") / 2}
              r={3}
              fill="rgb(255 224 102 / 0.9)"
            />
          ))}
        </svg>

        <span
          data-el="playhead"
          className="absolute inset-y-0 w-2 -translate-x-1/2 bg-ui-playhead"
          style={{ left: `${(playhead / LOOP) * 100}%` }}
        >
          <svg viewBox="0 0 12 14" className="absolute top-0 left-1/2 h-14 w-12 -translate-x-1/2">
            <path d="M0 0h12v8l-6 6-6-6z" fill="#ff5c8a" />
          </svg>
        </span>
      </div>
    </div>
  );
}

/* Inspector (InspectorView.swift and the Panels): icon tabs, the tab's title and a grouped form. */

const tabs: { id: Tab; title: string; icon: ReactNode }[] = [
  { id: "zoom", title: "Zoom", icon: <ZoomIn className="size-16" strokeWidth={1.8} /> },
  { id: "webcam", title: "Webcam", icon: <Webcam className="size-16" strokeWidth={1.8} /> },
  { id: "audio", title: "Audio", icon: <Volume2 className="size-16" strokeWidth={1.8} /> },
  { id: "blur", title: "Blur", icon: <DropHalfIcon className="size-16" /> },
  { id: "cursor", title: "Cursor", icon: <CursorArrowIcon className="size-17" /> },
  { id: "background", title: "Background", icon: <RectangleInsetIcon className="size-17" /> },
  { id: "subtitles", title: "Subtitles", icon: <CaptionsBubbleIcon className="size-16" /> },
];

function Inspector({ ui, text }: { ui: Ui; text: (key: Dragged) => string }) {
  const current = tabs.find((t) => t.id === ui.tab)!;
  return (
    <div className="flex h-full flex-col">
      <div className="px-14 pt-14">
        <div className="flex gap-2 ui-rounded-8 border border-white/9 bg-white/6 p-3">
          {tabs.map((tab) => (
            <span
              key={tab.id}
              data-target={`tab-${tab.id}`}
              className={cn(
                "grid h-30 flex-1 place-items-center ui-rounded-5 transition-colors duration-150",
                tab.id === ui.tab
                  ? "bg-ui-accent text-ui-on-accent shadow-[0_3px_7px_rgb(61_220_151/0.35)]"
                  : "text-ui-fg-2",
              )}
            >
              {tab.icon}
            </span>
          ))}
        </div>
        <div className="mt-14 flex items-baseline justify-between">
          <span className="ui-text-20 font-bold">{current.title}</span>
          {ui.tab === "zoom" && <span className="ui-text-11.5 text-ui-fg-3">3 zooms</span>}
        </div>
      </div>
      <div className="relative min-h-0 flex-1 overflow-hidden">
        {ui.tab === "zoom" && <ZoomPanel ui={ui} text={text} />}
        {ui.tab === "background" && <BackgroundPanel text={text} />}
        {ui.tab === "webcam" && <WebcamPanel ui={ui} />}
        {ui.tab === "cursor" && <CursorPanel ui={ui} />}
        {ui.tab === "audio" && <AudioPanel text={text} />}
      </div>
    </div>
  );
}

/** The form's scroll area; `offset` scrolls it (in points). */
function Form({
  offset = 0,
  thumb,
  children,
}: {
  offset?: number;
  thumb?: { top: number; height: number };
  children: ReactNode;
}) {
  return (
    <>
      <div
        className="px-16 pt-14 pb-20 transition-transform duration-700 ease-in-out"
        style={{ transform: `translateY(calc(var(--spacing) * ${-offset}))` }}
      >
        {children}
      </div>
      {thumb && <ScrollThumb {...thumb} />}
    </>
  );
}

const Caption = ({ children }: { children: ReactNode }) => (
  <p className="border-t border-white/8 py-9 ui-text-11 leading-[1.35] text-ui-fg-2">{children}</p>
);

function ZoomPanel({ ui, text }: { ui: Ui; text: (key: Dragged) => string }) {
  const selected = ui.selectedZoom !== null;
  const scrolled = selected && ui.scrolled;
  return (
    <Form
      offset={scrolled ? 300 : 0}
      thumb={selected ? { top: scrolled ? 236 : 6, height: 360 } : undefined}
    >
      <FormSection>
        <FormRow label="Zoom">
          <Toggle on />
        </FormRow>
      </FormSection>
      <FormSection header="New zooms in this recording">
        <SliderRow title="Scale" value="1.60×" position={0.6 / 3} />
        <SliderRow title="Ease in" value="0.32 s" position={0.27 / 0.95} />
        <SliderRow title="Hold" value="0.85 s" position={0.75 / 1.9} />
        <SliderRow title="Ease out" value="0.48 s" position={0.43 / 0.95} />
        <Caption>
          Defaults for new recordings, including zooms from clicks, are in Settings › Defaults.
        </Caption>
      </FormSection>
      <FormSection
        header="Zooms (3)"
        trailing={
          <span className="flex items-center gap-5 ui-text-12 font-normal">
            <Plus className="size-12" strokeWidth={2} />
            Add at Playhead
          </span>
        }
      >
        {zooms.map((z) => {
          const isSelected = z.id === ui.selectedZoom;
          return (
            <FormRow
              key={z.id}
              className={cn(
                "-mx-10 min-h-37 justify-start gap-10 px-10 transition-colors duration-150",
                isSelected && "bg-ui-accent/16",
              )}
            >
              <span data-target={`zoom-row-${z.id}`} className="flex items-center gap-10">
                <ZoomIn className="size-14 text-ui-zoom" strokeWidth={2} />
                <span className={cn("tabular-nums", isSelected && "font-semibold text-ui-accent")}>
                  {clock(z.start)}
                </span>
                <span
                  data-value={z.id === "z1" ? "zoomScale" : undefined}
                  className="text-ui-fg-2 tabular-nums"
                >
                  {z.id === "z1" ? text("zoomScale") : `${z.scale.toFixed(2)}×`}
                </span>
              </span>
            </FormRow>
          );
        })}
      </FormSection>
      {selected && (
        <FormSection header="Selected zoom">
          <FormRow label="Enabled">
            <Toggle on />
          </FormRow>
          <FormRow label="Instant (no easing)">
            <Toggle on={false} />
          </FormRow>
          <FormRow label="Mode">
            <PopUp value="Click" />
          </FormRow>
          <SliderRow
            title="Scale"
            value={text("zoomScale")}
            valueId="zoomScale"
            position="var(--zoom-scale)"
            target="slider-zoomScale"
          />
          <SliderRow title="Target X" value="95%" position={0.95} />
          <SliderRow title="Target Y" value="96%" position={0.96} />
          <SliderRow title="Ease in" value="0.60 s" position={0.55 / 0.95} />
        </FormSection>
      )}
    </Form>
  );
}

function BackgroundPanel({ text }: { text: (key: Dragged) => string }) {
  return (
    <Form>
      <FormSection>
        <FormRow label="Background">
          <Toggle on />
        </FormRow>
        <FormRow label="Aspect">
          <PopUp value="16:9" />
        </FormRow>
      </FormSection>
      <FormSection header="Frame">
        <SliderRow
          title="Padding"
          value={text("padding")}
          valueId="padding"
          position="var(--pad)"
          target="slider-padding"
        />
        <SliderRow
          title="Corner radius"
          value={text("radius")}
          valueId="radius"
          position="var(--rad)"
          target="slider-radius"
        />
        <SliderRow title="Shadow" value="50%" position={0.5} />
      </FormSection>
      <FormSection header="Fill">
        <FormRow label="Fill">
          <Segmented options={["Solid", "Gradient", "Image"]} selected="Gradient" width={193} />
        </FormRow>
        <FormRow label="From">
          <ColorWell color="#4f46e5" />
        </FormRow>
        <FormRow label="To">
          <ColorWell color="#db2777" />
        </FormRow>
        <SliderRow title="Angle" value="45°" position={45 / 360} />
      </FormSection>
    </Form>
  );
}

const corners = [
  { id: "topLeft", icon: SquareArrowUpLeft },
  { id: "topRight", icon: SquareArrowUpRight },
  { id: "center", icon: SquareDashed },
  { id: "bottomLeft", icon: SquareArrowDownLeft },
  { id: "bottomRight", icon: SquareArrowDownRight },
] as const;

function WebcamPanel({ ui }: { ui: Ui }) {
  const square = ui.webcamAspect === "Square";
  const circle = ui.webcamShape === "Circle";
  return (
    <Form offset={100} thumb={{ top: 90, height: 420 }}>
      <FormSection>
        <FormRow label="Show webcam">
          <Toggle on />
        </FormRow>
        <FormRow label="Mirror">
          <Toggle on={false} />
        </FormRow>
        <FormRow label="Shadow">
          <Toggle on />
        </FormRow>
      </FormSection>
      <FormSection header="Position">
        <FormRow className="gap-8">
          {corners.map(({ id, icon: Icon }) => (
            <span
              key={id}
              className="grid h-20 flex-1 place-items-center ui-rounded-5 bg-ui-accent/12 text-ui-accent"
            >
              <Icon className="size-12" strokeWidth={2} />
            </span>
          ))}
        </FormRow>
        <SliderRow title="X" value="3%" position={0.03} />
        <SliderRow title="Y" value={square ? "59%" : "75%"} position={square ? 0.589 : 0.747} />
      </FormSection>
      <FormSection header="Size and shape">
        <FormRow label="Size">
          <Segmented options={["S", "M", "L"]} selected="M" width={86} />
        </FormRow>
        <SliderRow title="Width" value="20%" position={0.15 / 0.45} />
        <FormRow label="Shape">
          <Segmented
            options={["Square", "Rounded", "Circle"]}
            selected={ui.webcamShape}
            width={198}
            target="webcam-shape"
          />
        </FormRow>
        <SliderRow
          title="Corner radius"
          value={circle ? "50%" : "10%"}
          position={circle ? 1 : 0.2}
        />
        <FormRow label="Aspect">
          <Segmented
            options={["Wide", "Square"]}
            selected={ui.webcamAspect}
            width={112}
            target="webcam-aspect"
          />
        </FormRow>
      </FormSection>
    </Form>
  );
}

function CursorPanel({ ui }: { ui: Ui }) {
  return (
    <Form thumb={{ top: 6, height: 400 }}>
      <FormSection>
        <FormRow label="Show cursor">
          <Toggle on />
        </FormRow>
        <FormRow label="Style">
          <Segmented options={["System", "Stylised", "Fixed"]} selected="System" width={183} />
        </FormRow>
        <FormRow label="Size">
          <Segmented
            options={["S", "M", "L"]}
            selected={ui.cursorSize}
            width={86}
            target="cursor-size"
          />
        </FormRow>
        <FormRow label="Smoothing">
          <PopUp value="Medium" />
        </FormRow>
      </FormSection>
      <FormSection>
        <FormRow label="Hide when idle">
          <Toggle on={false} />
        </FormRow>
        <FormRow label="Click pulse">
          <Toggle on />
        </FormRow>
      </FormSection>
      <FormSection header="Click highlight">
        <FormRow label="Highlight clicks">
          <Toggle on />
        </FormRow>
        <FormRow label="Colour">
          <ColorWell color="#3b82f6" />
        </FormRow>
        <SliderRow title="Radius" value="30 pt" position={20 / 90} />
        <SliderRow title="Duration" value="0.30 s" position={0.2 / 0.9} />
      </FormSection>
      <FormSection header="Drag trail">
        <FormRow label="Show trail while dragging">
          <Toggle on={false} />
        </FormRow>
        <SliderRow title="Length" value="5" position={3 / 13} />
      </FormSection>
    </Form>
  );
}

function AudioPanel({ text }: { text: (key: Dragged) => string }) {
  return (
    <Form>
      <FormSection header="System audio">
        <FormRow label="Enabled">
          <Toggle on />
        </FormRow>
        <FormRow label="Mute">
          <Toggle on={false} />
        </FormRow>
        <SliderRow title="Gain" value="+0.0 dB" position={20 / 30} />
        <LevelRow meter="meter-system" />
      </FormSection>
      <FormSection header="Microphone">
        <FormRow label="Enabled">
          <Toggle on />
        </FormRow>
        <FormRow label="Mute">
          <Toggle on={false} />
        </FormRow>
        <SliderRow
          title="Gain"
          value={text("gain")}
          valueId="gain"
          position="var(--gain)"
          target="slider-gain"
        />
        <LevelRow meter="meter-mic" />
      </FormSection>
    </Form>
  );
}

/** A level meter (LevelMeterView): green to yellow to red, revealed up to the level. */
function LevelRow({ meter }: { meter: string }) {
  return (
    <FormRow className="min-h-34 gap-10 ui-text-11.5">
      Level
      <span className="relative h-7 flex-1 overflow-hidden ui-rounded-3 bg-white/10">
        <span
          data-el={meter}
          className="absolute inset-y-0 left-0 w-0 overflow-hidden"
          style={{ width: "0%" }}
        >
          <span className="absolute inset-y-0 left-0 w-[calc(var(--spacing)*196)] bg-[linear-gradient(90deg,#34c759_0%,#34c759_60%,#ffcc00_85%,#ff3b30_100%)]" />
        </span>
      </span>
    </FormRow>
  );
}

/** The visitor's pointer, above everything. The loop moves it (`left`/`top` in points). */
function Pointer() {
  return (
    <span
      data-el="pointer"
      className="pointer-events-none absolute z-10"
      style={{
        left: `calc(var(--spacing) * ${REST_POINT.x})`,
        top: `calc(var(--spacing) * ${REST_POINT.y})`,
      }}
    >
      {/* oxlint-disable-next-line nextjs/no-img-element -- tiny static SVG, no optimisation needed */}
      <img
        src="/cursors/arrow.svg"
        alt=""
        className="block w-26 max-w-none origin-[12.5%_12.5%] -translate-x-[12.5%] -translate-y-[12.5%] drop-shadow-[0_1px_1px_rgb(0_0_0/0.3)] transition-[scale] duration-100 in-data-pressed:scale-85"
      />
    </span>
  );
}

/* The loop */

type Point = { x: number; y: number };

/**
 * Starts the demo on `root` (the 1280 pt stage) and returns a cleanup. Pauses while the demo is off screen
 * or the page is hidden; with reduced motion it draws one still frame and stops.
 */
export function runDemo(
  root: HTMLElement,
  values: Values,
  setUi: (update: (ui: Ui) => Ui) => void,
) {
  const one = (name: string) => root.querySelector<HTMLElement>(`[data-el="${name}"]`);
  const pointer = one("pointer")!;
  const camera = one("camera")!;
  const cursor = one("cursor")!;
  const ring = one("ring")!;
  const playhead = one("playhead")!;
  const time = one("time")!;
  const toggles = (
    [
      "published",
      "ticked",
      "progress",
      "progress-text",
      "progress-text-done",
      "popover",
      "email",
    ] as const
  ).map((name) => [name, one(name)] as const);

  let elapsed = 0;
  let lastLoopTime = 0;
  let lastTenth = -1;
  let pointerAt: Point = { ...REST_POINT };
  let move: { from: Point; to: Point; start: number; dur: number } | null = null;
  let drag: {
    key: Dragged;
    from: number;
    to: number;
    start: number;
    dur: number;
    track: { left: number; width: number; y: number };
  } | null = null;

  /** A target's box in stage points. */
  const box = (name: string) => {
    const el = root.querySelector(`[data-target="${name}"]`);
    if (!el) return null;
    const stageBox = root.getBoundingClientRect();
    const scale = stageBox.width / WIDTH;
    const r = el.getBoundingClientRect();
    return {
      left: (r.left - stageBox.left) / scale,
      top: (r.top - stageBox.top) / scale,
      width: r.width / scale,
      height: r.height / scale,
    };
  };

  const setValue = (key: Dragged, v: number) => {
    values[key] = v;
    root.style.setProperty(cssVar[key], String(fraction(key, v)));
    for (const el of root.querySelectorAll(`[data-value="${key}"]`))
      el.textContent = format[key](v);
  };

  const placePointer = (p: Point) => {
    pointerAt = p;
    pointer.style.left = `calc(var(--spacing) * ${p.x})`;
    pointer.style.top = `calc(var(--spacing) * ${p.y})`;
  };

  let pressTimer: number | undefined;
  const press = () => {
    window.clearTimeout(pressTimer);
    pointer.setAttribute("data-pressed", "");
    pressTimer = window.setTimeout(() => pointer.removeAttribute("data-pressed"), 140);
  };

  const begin = (step: Step, odd: boolean) => {
    switch (step.kind) {
      case "move": {
        const name = typeof step.to === "function" ? step.to(odd) : step.to;
        let to: Point = REST_POINT;
        const b = name === REST ? null : box(name);
        if (b && name.startsWith("slider-")) {
          const key = name.slice("slider-".length) as Dragged;
          to = { x: b.left + fraction(key, values[key]) * b.width, y: b.top + b.height / 2 };
        } else if (b) {
          to = { x: b.left + b.width / 2, y: b.top + b.height / 2 };
        }
        move = { from: pointerAt, to, start: elapsed, dur: step.dur };
        break;
      }
      case "click":
        press();
        setUi((ui) => {
          if (step.tab) return { ...ui, tab: step.tab, scrolled: false };
          if (step.select) return { ...ui, selectedZoom: step.select };
          if (step.flip) {
            const key = typeof step.flip === "function" ? step.flip(odd) : step.flip;
            return { ...ui, [key]: flipped[key][odd ? 0 : 1] };
          }
          return ui;
        });
        break;
      case "scroll":
        setUi((ui) => ({ ...ui, scrolled: step.down }));
        break;
      case "drag": {
        const b = box(`slider-${step.value}`);
        if (!b) break;
        const range = dragged[step.value];
        drag = {
          key: step.value,
          from: odd ? range.to : range.from,
          to: odd ? range.from : range.to,
          start: elapsed,
          dur: step.dur,
          track: { left: b.left, width: b.width, y: b.top + b.height / 2 },
        };
        pointer.setAttribute("data-pressed", "");
        break;
      }
    }
  };

  /** Starts every step with `from < at <= to` in loop `cycle`. */
  const runSteps = (from: number, to: number, cycle: number) => {
    for (const step of script) if (step.at > from && step.at <= to) begin(step, cycle % 2 === 1);
  };

  const frame = (t: number) => {
    const cycle = Math.floor(elapsed / LOOP);
    if (t < lastLoopTime) {
      runSteps(lastLoopTime, LOOP, cycle - 1);
      runSteps(-1, t, cycle);
    } else {
      runSteps(lastLoopTime, t, cycle);
    }
    lastLoopTime = t;

    if (move) {
      const p = Math.min(1, (elapsed - move.start) / move.dur);
      const e = easeInOut(p);
      placePointer({
        x: move.from.x + (move.to.x - move.from.x) * e,
        y: move.from.y + (move.to.y - move.from.y) * e,
      });
      if (p >= 1) move = null;
    }
    if (drag) {
      const p = Math.min(1, (elapsed - drag.start) / drag.dur);
      const v = drag.from + (drag.to - drag.from) * easeInOut(p);
      setValue(drag.key, v);
      placePointer({
        x: drag.track.left + fraction(drag.key, v) * drag.track.width,
        y: drag.track.y,
      });
      if (p >= 1) {
        drag = null;
        pointer.removeAttribute("data-pressed");
      }
    }

    // The recording.
    const snapshot = recordingAt(t, (z) => (z.id === "z1" ? values.zoomScale : z.scale));
    const cam = snapshot.camera;
    // As in the app (RenderKit Zoom.swift), a click or manual zoom scales about its target.
    camera.style.transformOrigin = `${cam.origin[0]}% ${cam.origin[1]}%`;
    camera.style.transform = `scale(${cam.scale})`;
    const [cx, cy] = snapshot.cursor;
    cursor.style.left = `${cx}%`;
    cursor.style.top = `${cy}%`;
    const lastClick = clicks.findLast((c) => c <= t);
    const sinceClick = lastClick === undefined ? Infinity : t - lastClick;
    cursor.style.scale = sinceClick < 0.18 ? "0.82" : "1";
    if (lastClick !== undefined && sinceClick < 0.5) {
      const [rx, ry] = cursorAt(lastClick);
      const p = sinceClick / 0.5;
      ring.style.left = `${rx}%`;
      ring.style.top = `${ry}%`;
      ring.style.transform = `translate(-50%, -50%) scale(${0.35 + 0.65 * easeInOut(Math.min(1, p * 1.6))})`;
      ring.style.opacity = String(1 - p);
    } else {
      ring.style.opacity = "0";
    }
    for (const [name, el] of toggles) el?.toggleAttribute("data-on", snapshot.on[name]);

    // The editor around it.
    playhead.style.left = `${(t / LOOP) * 100}%`;
    const tenth = Math.floor(t * 10);
    if (tenth !== lastTenth) {
      lastTenth = tenth;
      time.textContent = clock(t);
      const mic = one("meter-mic");
      const system = one("meter-system");
      const wobble = 0.5 + 0.5 * Math.sin(tenth * 2.3) * Math.cos(tenth * 0.7);
      if (mic) {
        const gain = 10 ** ((values.gain + 3) / 40);
        mic.style.width = `${talking(t) ? Math.min(96, (38 + 30 * wobble) * gain) : 3}%`;
      }
      if (system) system.style.width = `${sinceClick < 0.35 ? 46 - sinceClick * 80 : 0}%`;
    }
  };

  const still = window.matchMedia("(prefers-reduced-motion: reduce)");
  let raf = 0;
  let last = 0;
  let visible = false;
  const tick = (now: number) => {
    elapsed += Math.max(0, Math.min(0.1, (now - last) / 1000));
    last = now;
    frame(elapsed % LOOP);
    raf = requestAnimationFrame(tick);
  };
  const update = () => {
    const run = visible && !document.hidden && !still.matches;
    if (run && !raf) {
      last = performance.now();
      raf = requestAnimationFrame(tick);
    } else if (!run && raf) {
      cancelAnimationFrame(raf);
      raf = 0;
    }
  };
  // Freeze the current frame when the preference changes; resume from the same edit state.
  if (still.matches) {
    elapsed = lastLoopTime = 0.9;
    frame(0.9);
  }
  still.addEventListener("change", update);
  const observer = new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    update();
  });
  observer.observe(root);
  document.addEventListener("visibilitychange", update);
  return () => {
    observer.disconnect();
    still.removeEventListener("change", update);
    window.clearTimeout(pressTimer);
    pointer.removeAttribute("data-pressed");
    document.removeEventListener("visibilitychange", update);
    cancelAnimationFrame(raf);
  };
}

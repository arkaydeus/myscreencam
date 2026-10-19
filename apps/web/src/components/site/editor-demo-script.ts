/*
 * The hero editor's timeline: what the 24 s recording does (zooms, clicks, the cursor's path) and what the
 * visitor's pointer does in the editor around it (switching inspector tabs, dragging sliders). Both run off
 * one clock, so the timeline blocks, the preview and the inspector stay in step. Kept free of React so the
 * site tests can check it.
 */

/** The recording's edited duration, and the length of one loop of the demo. */
export const LOOP = 24;

/** Where the screen recording was cut (two segments on the Screen row). */
export const CUT = 12.6;

/** Points the zooms and clicks aim at, as percentages of the recording. */
export const spots = {
  publish: [87.5, 93],
  task: [26.6, 43.4],
  share: [94.6, 3.6],
  outside: [62, 70],
  start: [52, 30],
} as const satisfies Record<string, readonly [number, number]>;

export type Zoom = {
  id: string;
  start: number;
  easeIn: number;
  hold: number;
  easeOut: number;
  scale: number;
  target: readonly [number, number];
};

export const zooms: readonly Zoom[] = [
  { id: "z1", start: 1.6, easeIn: 0.6, hold: 4.2, easeOut: 0.7, scale: 1.85, target: [95, 96] },
  { id: "z2", start: 9.1, easeIn: 0.6, hold: 3.6, easeOut: 0.7, scale: 1.7, target: spots.task },
  { id: "z3", start: 15.9, easeIn: 0.6, hold: 3.8, easeOut: 0.7, scale: 1.6, target: [98, 14] },
];

export const zoomEnd = (z: Zoom) => z.start + z.easeIn + z.hold + z.easeOut;

/** Clicks in the recording: publish, tick a task, open Share, click away to close it. */
export const clicks = [2.1, 9.6, 16.0, 21.8] as const;

/** A blur mask over the email address in the Share popover. */
export const blurMask = { start: 16.1, end: 21.9 } as const;

/** The popover is open between the Share click and the click away. */
export const popoverOpen = (t: number) => t >= clicks[2] && t < clicks[3];

/** The recorded cursor's path: rests and moves, in recording percentages. */
const cursorPath: readonly { t: number; at: readonly [number, number] }[] = [
  { t: 0, at: spots.start },
  { t: 0.5, at: spots.start },
  { t: 1.9, at: spots.publish },
  { t: 4.6, at: spots.publish },
  { t: 5.6, at: [76, 76] },
  { t: 8.4, at: [58, 62] },
  { t: 9.4, at: spots.task },
  { t: 12.4, at: spots.task },
  { t: 14.4, at: [72, 30] },
  { t: 15.8, at: spots.share },
  { t: 16.6, at: spots.share },
  { t: 17.4, at: [80, 17] },
  { t: 19.8, at: [84, 26] },
  { t: 21.6, at: spots.outside },
  { t: 22.4, at: spots.outside },
  { t: 24, at: spots.start },
];

export const easeInOut = (x: number) => (x < 0.5 ? 4 * x * x * x : 1 - (-2 * x + 2) ** 3 / 2);

const lerp = (a: number, b: number, x: number) => a + (b - a) * x;

export function cursorAt(t: number): readonly [number, number] {
  for (let i = 1; i < cursorPath.length; i++) {
    const a = cursorPath[i - 1];
    const b = cursorPath[i];
    if (t <= b.t) {
      const x = easeInOut(b.t === a.t ? 1 : (t - a.t) / (b.t - a.t));
      return [lerp(a.at[0], b.at[0], x), lerp(a.at[1], b.at[1], x)];
    }
  }
  return spots.start;
}

/**
 * The camera at `t`: the zoom's scale (eased in, held, eased out) and the point it scales about (its target, which stays put on screen). `scaleOf` lets the
 * inspector's live Scale slider override a zoom's scale.
 */
export function cameraAt(
  t: number,
  scaleOf: (zoom: Zoom) => number = (z) => z.scale,
): { scale: number; origin: readonly [number, number] } {
  let origin: readonly [number, number] = zooms[0].target;
  for (const z of zooms) {
    if (t < z.start) break;
    origin = z.target;
    const scale = scaleOf(z);
    const t1 = z.start + z.easeIn;
    const t2 = t1 + z.hold;
    const t3 = t2 + z.easeOut;
    if (t < t1) return { scale: lerp(1, scale, easeInOut((t - z.start) / z.easeIn)), origin };
    if (t < t2) return { scale, origin };
    if (t < t3) return { scale: lerp(scale, 1, easeInOut((t - t2) / z.easeOut)), origin };
  }
  return { scale: 1, origin };
}

/** The shared recording snapshot for the live hero and paused illustrations. */
export function recordingAt(t: number, scaleOf?: (zoom: Zoom) => number) {
  return {
    camera: cameraAt(t, scaleOf),
    cursor: cursorAt(t),
    on: {
      published: t >= clicks[0],
      ticked: t >= clicks[1],
      progress: t >= clicks[1],
      "progress-text": t >= clicks[1],
      "progress-text-done": t >= clicks[1],
      popover: popoverOpen(t),
      email: t >= blurMask.start && t < blurMask.end,
    },
  };
}

/* The visitor's pointer. */

export type Tab = "zoom" | "webcam" | "audio" | "blur" | "cursor" | "background" | "subtitles";

/** Values the pointer drags; each loop drags them the other way. */
export const dragged = {
  zoomScale: { from: 1.85, to: 2.3, min: 1, max: 4 },
  padding: { from: 0.06, to: 0.12, min: 0, max: 0.3 },
  radius: { from: 0.02, to: 0.07, min: 0, max: 0.2 },
  gain: { from: -3, to: 2, min: -20, max: 10 },
} as const;

export type Dragged = keyof typeof dragged;

/** Choices the pointer clicks; each loop flips them. */
export const flipped = {
  webcamAspect: ["Wide", "Square"],
  webcamShape: ["Rounded", "Circle"],
  cursorSize: ["M", "L"],
} as const;

export type Flipped = keyof typeof flipped;

export type Step =
  | { at: number; kind: "move"; dur: number; to: string | ((odd: boolean) => string) }
  | {
      at: number;
      kind: "click";
      tab?: Tab;
      select?: string;
      flip?: Flipped | ((odd: boolean) => Flipped);
    }
  | { at: number; kind: "scroll"; down: boolean }
  | { at: number; kind: "drag"; dur: number; value: Dragged };

/** `data-target` of the option a flip click lands on. */
const flipTarget =
  (key: Flipped, prefix: string) =>
  (odd: boolean): string =>
    `${prefix}-${flipped[key][odd ? 0 : 1]}`;

const webcamTarget = (key: "webcamAspect" | "webcamShape", odd: boolean) =>
  flipTarget(key, key === "webcamAspect" ? "webcam-aspect" : "webcam-shape")(odd);

export const REST = "rest";

/** The pointer's script, in loop seconds. Targets are `data-target` names in the editor. */
export const script: readonly Step[] = [
  { at: 0.3, kind: "move", dur: 0.8, to: "zoom-row-z1" },
  { at: 1.2, kind: "click", select: "z1" },
  { at: 1.6, kind: "scroll", down: true },
  { at: 2.3, kind: "move", dur: 0.6, to: "slider-zoomScale" },
  { at: 3.0, kind: "drag", dur: 1.2, value: "zoomScale" },
  { at: 4.6, kind: "move", dur: 0.8, to: "tab-background" },
  { at: 5.5, kind: "click", tab: "background" },
  { at: 6.1, kind: "move", dur: 0.6, to: "slider-padding" },
  { at: 6.8, kind: "drag", dur: 1.0, value: "padding" },
  { at: 8.0, kind: "move", dur: 0.5, to: "slider-radius" },
  { at: 8.6, kind: "drag", dur: 0.8, value: "radius" },
  { at: 9.8, kind: "move", dur: 0.7, to: "tab-webcam" },
  { at: 10.6, kind: "click", tab: "webcam" },
  // A square, circular webcam; the next loop turns it back into a rounded wide one, shape first.
  {
    at: 11.3,
    kind: "move",
    dur: 0.6,
    to: (odd) => webcamTarget(odd ? "webcamShape" : "webcamAspect", odd),
  },
  { at: 12.0, kind: "click", flip: (odd) => (odd ? "webcamShape" : "webcamAspect") },
  {
    at: 12.6,
    kind: "move",
    dur: 0.6,
    to: (odd) => webcamTarget(odd ? "webcamAspect" : "webcamShape", odd),
  },
  { at: 13.3, kind: "click", flip: (odd) => (odd ? "webcamAspect" : "webcamShape") },
  { at: 14.2, kind: "move", dur: 0.7, to: "tab-cursor" },
  { at: 15.0, kind: "click", tab: "cursor" },
  { at: 15.6, kind: "move", dur: 0.6, to: flipTarget("cursorSize", "cursor-size") },
  { at: 16.3, kind: "click", flip: "cursorSize" },
  { at: 17.4, kind: "move", dur: 0.8, to: "tab-audio" },
  { at: 18.3, kind: "click", tab: "audio" },
  { at: 19.0, kind: "move", dur: 0.6, to: "slider-gain" },
  { at: 19.7, kind: "drag", dur: 0.9, value: "gain" },
  { at: 21.4, kind: "move", dur: 0.8, to: "tab-zoom" },
  { at: 22.3, kind: "click", tab: "zoom" },
  { at: 22.8, kind: "move", dur: 0.9, to: REST },
];

/** "m:ss.cc", as the transport's time label shows it. */
export function clock(seconds: number): string {
  const hundredths = Math.floor(Math.max(0, seconds) * 100 + 1e-6);
  const s = Math.floor(hundredths / 100);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}.${String(hundredths % 100).padStart(2, "0")}`;
}

/* The narration: what the microphone hears, as the subtitles transcribe it. */

/** Subtitle cues, in seconds: the narrator talks only inside them. */
export const narration = [
  { start: 0.4, end: 3.8, text: "Here’s the onboarding launch. First, publish the changes." },
  { start: 4.5, end: 8.9, text: "Publishing sends the new checklist to the whole team." },
  { start: 10.1, end: 14.6, text: "Tick off the product tour and the progress bar updates." },
  { start: 15.3, end: 19.9, text: "Then share the project with a teammate." },
  { start: 20.7, end: 23.5, text: "That’s it. The launch is ready to go." },
] as const;

export const talking = (t: number) => narration.some((cue) => t > cue.start && t < cue.end);

/** A repeatable 0…1 value per column (an integer hash, so server and browser agree exactly). */
export const noise = (i: number) => {
  let h = Math.imul(i ^ 0x9e3779b9, 0x85ebca6b);
  h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35);
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
};

/** `count` waveform peaks (0…1) across the loop, one per 2 pt timeline column. */
export function peaks(count: number, level: (t: number, i: number) => number) {
  return Array.from({ length: count }, (_, i) => {
    const t = (i * LOOP) / count;
    return Math.min(1, Math.max(0, level(t, i)));
  });
}

/** The microphone's level: speech while the narrator talks, near silence between. */
export const micLevel = (t: number, i: number) =>
  talking(t) ? 0.25 + 0.6 * noise(i) * (0.6 + 0.4 * Math.sin(t * 7)) : 0.02 * noise(i);

/** An SVG path of 1.5 pt bars, one per peak, centred in a row `height` tall at `top`. */
export function waveformPath(values: number[], top: number, height: number) {
  const mid = top + height / 2;
  const half = height / 2 - 2;
  return values
    .map((v, i) => {
      if (v < 0.004) return "";
      const h = Math.round(Math.max(0.5, v * half) * 10) / 10;
      return `M${i * 2} ${(mid - h).toFixed(1)}h1.5v${(h * 2).toFixed(1)}h-1.5z`;
    })
    .join("");
}

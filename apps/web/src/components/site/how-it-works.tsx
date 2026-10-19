import { AudioLines, EyeOff, Layers } from "lucide-react";

import { RecorderWindow, ExportSheetWindow, TimelineWindow } from "@/components/site/app-windows";
import { sectionTitle } from "@/components/site/brand";
import { SubtitlesWindow } from "@/components/site/subtitles-window";
import { cn } from "@/lib/utils";

/** Presets as shipped in apps/macos (ExportKit/ExportPreset.swift). */
const presets = [
  { name: "Web", detail: "H.264, up to 1080p, 30 fps" },
  { name: "Smooth", detail: "H.264, up to 1080p, 60 fps" },
  { name: "Compact", detail: "HEVC, up to 1080p, 24 fps" },
  { name: "Master", detail: "ProRes 422, full size, 60 fps" },
  { name: "GIF", detail: "Up to 720 px, 15 fps" },
];

const steps = [
  {
    title: "Record.",
    visual: <RecorderWindow className="mx-auto max-w-[620px]" />,
    alt: "The New Recording window: a display, window or region source with a preview, camera and microphone pickers, options and the Start Recording button.",
    lead: "A whole display, a single window, or a region you drag out.",
    points: [
      "Webcam, microphone and system audio in the same take, with no audio driver to install.",
      "Pause and resume without starting a new recording.",
      "A countdown, a small floating control bar and a menu bar item keep out of your way.",
      "Clicks and cursor movement are saved with the video, ready for the editor.",
    ],
  },
  {
    title: "Edit.",
    visual: <TimelineWindow />,
    alt: "The editor’s transport bar and timeline: screen and webcam rows with a cut, system and microphone waveforms, zoom blocks, a blur mask and click markers.",
    lead: "The preview is drawn by the same renderer as the export.",
    points: [
      "Cut, trim and delete sections on a timeline with audio waveforms.",
      "Add zooms by hand, on every click, or following the mouse.",
      "Every change can be undone, and edits save as you go.",
      "Save a look as a preset and reuse it on the next recording.",
    ],
  },
  {
    title: "Annotate.",
    visual: <SubtitlesWindow />,
    alt: "The editor’s Subtitles tab: the transcript as timed subtitles, style controls with Highlight spoken word turned on, and the preview showing a subtitle with the spoken word in yellow.",
    lead: "Subtitles from your narration, transcribed on your Mac.",
    points: [
      "Generate subtitles with a speech model that runs on your Mac: Parakeet Ultra for 25 European languages, or Qwen for 30.",
      "Fix a word, adjust a subtitle’s timing, or drag it into place on the preview.",
      "Pick the font, colours, outline and background, and highlight each word as it’s spoken.",
      "Select a stumble in the transcript to cut those words from the video.",
      "Subtitles are burned into the export, with an .srt file beside it if you want one.",
    ],
  },
  {
    title: "Export.",
    visual: <ExportSheetWindow className="mx-auto max-w-[420px]" />,
    alt: "The Export sheet: preset, format, quality, frame rate, resolution and audio, with the output size and an estimate of the file size.",
    lead: "Encoded on the media engine, with a preset for every destination.",
    points: [],
  },
];

const more = [
  {
    icon: EyeOff,
    title: "Blur",
    body: "Hide an email address, a token or a customer’s name for just the part of the video where it’s showing.",
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

export function HowItWorks() {
  return (
    <section id="how" className="scroll-mt-13 py-18 sm:py-30">
      <div className="page-width">
        <h2 className={sectionTitle}>
          Record. Edit. Annotate. Export.
          <br />
          <span className="text-muted-foreground">Raw take to shareable video.</span>
        </h2>
        <ol className="mt-8 grid gap-3 sm:mt-14 sm:gap-5">
          {steps.map((step, index) => (
            <li
              key={step.title}
              className={cn(
                "grid items-center gap-8 rounded-3xl bg-paper px-6 py-7 sm:rounded-[28px] sm:px-10 sm:py-10 lg:gap-14 lg:p-14",
                // The window alternates sides: right of the text, then left of it.
                index % 2 === 0
                  ? "lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)]"
                  : "lg:grid-cols-[minmax(0,7fr)_minmax(0,5fr)]",
              )}
            >
              <figure>
                <div aria-hidden>{step.visual}</div>
                <figcaption className="sr-only">{step.alt}</figcaption>
              </figure>
              <div className={cn(index % 2 === 0 && "lg:order-first")}>
                <p className="text-xs font-semibold text-primary sm:text-sm">Step {index + 1}</p>
                <h3 className="mt-1 text-[32px] leading-[1.1] font-semibold sm:mt-1.5 sm:text-[40px]">
                  {step.title}
                </h3>
                <p className="mt-3 text-[17px] leading-[1.41] font-semibold sm:mt-4 sm:text-[19px] sm:leading-[1.42]">
                  {step.lead}
                </p>
                {step.points.length > 0 ? (
                  <ul className="mt-5 text-[15px] leading-[1.47] text-muted-foreground sm:mt-6">
                    {step.points.map((point) => (
                      <li key={point} className="border-t border-rule py-3 last:pb-0">
                        {point}
                      </li>
                    ))}
                  </ul>
                ) : (
                  <table className="mt-5 w-full text-left text-[15px] leading-[1.47] sm:mt-6">
                    <caption className="sr-only">Export presets</caption>
                    <tbody>
                      {presets.map((preset) => (
                        <tr key={preset.name} className="border-t border-rule">
                          <th scope="row" className="py-3 pr-3 font-semibold">
                            {preset.name}
                          </th>
                          <td className="py-3 text-muted-foreground">{preset.detail}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
              </div>
            </li>
          ))}
        </ol>
        <ul className="mt-3 grid gap-3 sm:mt-5 sm:gap-5 lg:grid-cols-3">
          {more.map((item) => (
            <li
              key={item.title}
              className="flex gap-4 rounded-3xl bg-paper p-6 sm:gap-4.5 sm:rounded-[28px] sm:px-9 sm:py-8"
            >
              <item.icon
                aria-hidden
                className="size-6.5 shrink-0 text-primary sm:size-7"
                strokeWidth={1.75}
              />
              <div>
                <h3 className="text-[17px] font-semibold sm:text-[19px]">{item.title}</h3>
                <p className="mt-1 text-[15px] leading-[1.47] text-muted-foreground sm:mt-1.5">
                  {item.body}
                </p>
              </div>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}

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
    title: "Record",
    lead: "Capture a whole display, a single window, or a region you drag out.",
    points: [
      "Webcam, microphone and system audio in the same take, with no audio driver to install.",
      "Pause and resume without starting a new recording.",
      "A countdown, a small floating control bar and a menu bar item keep out of your way.",
      "Clicks and cursor movement are saved with the video, ready for the editor.",
    ],
  },
  {
    title: "Edit",
    lead: "The preview is drawn by the same renderer as the export, so what you see is what you get.",
    points: [
      "Cut, trim and delete sections on a timeline with audio waveforms.",
      "Add zooms by hand, on every click, or following the mouse.",
      "Every change can be undone, and edits save as you go.",
      "Save a look as a preset and reuse it on the next recording.",
    ],
  },
  {
    title: "Export",
    lead: "Encoding runs on your Mac’s media engine, which leaves the CPU free for other work.",
    points: [],
  },
];

export function HowItWorks() {
  return (
    <section id="how" className="scroll-mt-8 border-t border-rule">
      <div className="mx-auto w-full max-w-7xl px-5 py-20 sm:px-8 sm:py-28">
        <h2 className="max-w-[20ch] font-display text-4xl leading-none font-extrabold tracking-[-0.03em] sm:text-5xl">
          From raw take to shareable video in three steps.
        </h2>
        <ol className="mt-14 grid gap-12 md:grid-cols-3 md:gap-10">
          {steps.map((step, index) => (
            <li key={step.title} className="flex flex-col">
              <div className="flex items-baseline gap-3 border-b-2 border-ink pb-3">
                <span className="font-display text-2xl font-extrabold text-ultramarine tabular-nums">
                  {index + 1}
                </span>
                <h3 className="font-display text-2xl font-extrabold tracking-tight">
                  {step.title}
                </h3>
              </div>
              <p className="mt-5 text-lg leading-snug font-medium">{step.lead}</p>
              {step.points.length > 0 ? (
                <ul className="mt-5 space-y-3 text-muted-foreground">
                  {step.points.map((point) => (
                    <li key={point} className="flex gap-3 leading-relaxed">
                      <span aria-hidden className="mt-2.5 h-px w-3 shrink-0 bg-ink/40" />
                      {point}
                    </li>
                  ))}
                </ul>
              ) : (
                <table className="mt-5 w-full text-left text-sm">
                  <caption className="sr-only">Export presets</caption>
                  <tbody>
                    {presets.map((preset) => (
                      <tr key={preset.name} className="border-b border-rule last:border-0">
                        <th scope="row" className="py-2.5 pr-4 font-semibold">
                          {preset.name}
                        </th>
                        <td className="py-2.5 text-muted-foreground">{preset.detail}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </li>
          ))}
        </ol>
      </div>
    </section>
  );
}

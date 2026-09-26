/**
 * Numbers measured on the optimised build; sources in apps/macos/docs/perf-baseline.md. Update both
 * together.
 */
const measurements = [
  {
    figure: "18%",
    unit: "of one CPU core",
    scenario:
      "Recording a 4K Retina display at 60 fps, with webcam, microphone and system audio, on a busy screen.",
  },
  {
    figure: "300 MB",
    unit: "of memory",
    scenario: "For that same recording, on average.",
  },
  {
    figure: "6×",
    unit: "faster than real time",
    scenario:
      "Exporting a 3 minute 47 second 4K recording, with webcam and 16 zooms, to HEVC in 37 s.",
  },
  {
    figure: "0.1%",
    unit: "CPU at rest",
    scenario: "Sitting idle with four editor windows open.",
  },
];

export function Performance() {
  return (
    <section id="performance" className="scroll-mt-8 bg-ink text-white">
      <div className="mx-auto grid w-full max-w-7xl gap-14 px-5 py-20 sm:px-8 sm:py-28 lg:grid-cols-[minmax(0,26rem)_1fr]">
        <div>
          <h2 className="font-display text-4xl leading-none font-extrabold tracking-[-0.03em] sm:text-5xl">
            Light enough to leave running.
          </h2>
          <div className="mt-6 space-y-4 text-lg leading-relaxed text-white/70">
            <p>
              MyScreenArt is built only on Apple’s own frameworks. ScreenCaptureKit captures,
              VideoToolbox encodes on the media engine, and Core Image composites on the GPU with
              Metal.
            </p>
            <p>
              Frames stay on the GPU from capture to export, and a screen that isn’t changing isn’t
              re-encoded frame after frame. Your fans stay quiet and your battery lasts.
            </p>
          </div>
        </div>

        <div>
          <table className="w-full text-left">
            <caption className="sr-only">Measured resource use</caption>
            <tbody>
              {measurements.map((m) => (
                <tr
                  key={m.unit}
                  className="flex flex-col border-b border-white/15 py-6 first:border-t sm:table-row sm:py-0 sm:align-baseline"
                >
                  <th scope="row" className="pr-6 font-normal whitespace-nowrap sm:py-6 sm:pr-10">
                    <span className="block font-figures text-4xl font-extrabold tracking-tight text-cadmium sm:text-5xl">
                      {m.figure}
                    </span>
                    <span className="mt-1 block text-sm text-white/60">{m.unit}</span>
                  </th>
                  <td className="pt-3 leading-relaxed text-white/80 sm:py-6">{m.scenario}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="mt-6 text-sm text-white/50">
            Measured on a MacBook Pro with M5 Max in September 2026. Your results depend on your
            Mac, your display and what’s on screen.
          </p>
        </div>
      </div>
    </section>
  );
}

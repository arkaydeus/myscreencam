import { FootnoteRef } from "@/components/site/brand";

/**
 * Numbers measured on the optimised build; sources in apps/macos/docs/perf-baseline.md. Update both
 * together, and the footnote in the site footer.
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

const frameworks = [
  { name: "ScreenCaptureKit", role: "Captures screen and sound" },
  { name: "VideoToolbox", role: "Encodes on the media engine" },
  { name: "Core Image", role: "Composites every frame" },
  { name: "Metal", role: "Keeps it all on the GPU" },
];

export function Performance() {
  return (
    <section id="performance" className="scroll-mt-13 bg-black text-[#f5f5f7]">
      <div className="page-width py-22 text-center sm:pt-35 sm:pb-32">
        <p className="text-[17px] font-semibold text-cadmium sm:text-[21px]">Performance</p>
        <h2 className="mx-auto mt-2 max-w-[900px] text-[40px] leading-[1.1] font-semibold tracking-[-0.01em] text-balance sm:mt-3 sm:text-[56px] lg:text-[72px] lg:leading-[1.05] lg:tracking-[-0.015em]">
          Light enough to leave running.
        </h2>
        <p className="mx-auto mt-4 max-w-[720px] text-[17px] leading-[1.47] text-pretty text-[#a1a1a6] sm:mt-6 sm:text-[21px] sm:leading-[1.43]">
          Frames stay on the GPU from capture to export, and a screen that isn’t changing isn’t
          re-encoded frame after frame. Your fans stay quiet and your battery lasts.
        </p>
        <dl className="mt-12 grid grid-cols-2 gap-x-5 gap-y-9 text-left sm:mt-20 lg:grid-cols-4 lg:gap-0">
          {measurements.map((m) => (
            <div
              key={m.unit}
              className="flex flex-col border-t border-[#333336] pt-4 lg:border-t-0 lg:border-l lg:px-7 lg:pt-0"
            >
              <dt className="order-2 mt-2 text-[15px] font-semibold sm:mt-2.5 sm:text-[17px]">
                {m.unit}
                <FootnoteRef />
              </dt>
              <dd className="order-1 text-[40px] leading-none font-semibold tracking-[-0.02em] text-white sm:text-[64px]">
                {m.figure}
              </dd>
              <dd className="order-3 mt-1.5 text-xs leading-[1.4] text-[#a1a1a6] sm:mt-2.5 sm:text-sm sm:leading-[1.43]">
                {m.scenario}
              </dd>
            </div>
          ))}
        </dl>
        <ul className="mt-12 grid grid-cols-2 gap-2.5 text-left sm:mt-22 sm:gap-4 lg:grid-cols-4">
          {frameworks.map((f) => (
            <li key={f.name} className="rounded-2xl bg-ink p-4.5 sm:rounded-[22px] sm:p-7">
              <p className="text-[15px] font-semibold sm:text-[19px]">{f.name}</p>
              <p className="mt-1 text-xs text-[#a1a1a6] sm:mt-1.5 sm:text-sm">{f.role}</p>
            </li>
          ))}
        </ul>
        <p className="mt-5 text-[15px] text-[#a1a1a6] sm:mt-7 sm:text-[17px]">
          Built only on Apple’s own frameworks.
        </p>
      </div>
    </section>
  );
}

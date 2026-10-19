import {
  AppWindow,
  ChevronRight,
  CircleDot,
  Mic,
  Monitor,
  RefreshCw,
  Share,
  SlidersHorizontal,
  SquareDashed,
  Video,
} from "lucide-react";
import type { ReactNode } from "react";

import { AppButton, AppFrame, MacWindow, PopUp, Segmented, Toggle } from "@/components/site/app-ui";
import { Portrait } from "@/components/site/brand";
import { DemoRecording } from "@/components/site/demo-recording";
import { TimelineCloseUp } from "@/components/site/editor-demo";

/*
 * Still drawings of My Screen Cam's other windows, for "How it works". Like the hero, they follow the
 * SwiftUI layouts in apps/macos (RecorderView.swift, ExportSheet.swift) point for point.
 */

/** `ThemeGroupBoxStyle`: the label above a floating panel. */
function GroupBox({
  label,
  icon,
  children,
}: {
  label: string;
  icon: ReactNode;
  children: ReactNode;
}) {
  return (
    <div className="ui-rounded-10 border border-white/8 bg-ui-panel p-12">
      <p className="flex items-center gap-6 ui-text-12 font-semibold text-ui-fg-2">
        {icon}
        {label}
      </p>
      <div className="mt-8 p-4">{children}</div>
    </div>
  );
}

/** The New Recording window (RecorderView.swift). */
export function RecorderWindow({ className }: { className?: string }) {
  return (
    <AppFrame width={756} height={664} className={className}>
      <MacWindow title="New Recording">
        <div className="flex gap-16 px-20 pt-8">
          <div className="w-400 shrink-0">
            <GroupBox label="Source" icon={<Monitor className="size-13" strokeWidth={2} />}>
              <span className="flex h-22 ui-rounded-6 bg-white/7 p-1 ui-text-12">
                {[
                  { label: "Display", icon: Monitor },
                  { label: "Window", icon: AppWindow },
                  { label: "Region", icon: SquareDashed },
                ].map(({ label, icon: Icon }, i) => (
                  <span
                    key={label}
                    className={
                      i === 0
                        ? "flex flex-1 items-center justify-center gap-5 ui-rounded-5 bg-ui-accent font-medium text-ui-on-accent"
                        : "flex flex-1 items-center justify-center gap-5 text-ui-fg-2"
                    }
                  >
                    <Icon className="size-12" strokeWidth={2} />
                    {label}
                  </span>
                ))}
              </span>
              <div className="mt-10 flex items-center gap-8 ui-text-13">
                Display
                <PopUp value="Built-in Retina Display" />
              </div>
              <div className="relative mt-10 grid h-210 place-items-center ui-rounded-8 border border-white/8 bg-ui-stage p-6">
                <DesktopStill />
                <span className="absolute top-4 right-4 grid size-30 place-items-center text-ui-fg">
                  <RefreshCw className="size-14" strokeWidth={2} />
                </span>
              </div>
              <p className="mt-10 ui-text-13 text-ui-accent">Choose with System Picker…</p>
            </GroupBox>
          </div>
          <div className="flex w-300 shrink-0 flex-col gap-12">
            <GroupBox label="Camera" icon={<Video className="size-13" strokeWidth={2} />}>
              <PopUp value="FaceTime HD Camera" />
              <div className="mt-8 h-150 overflow-hidden ui-rounded-8 bg-[linear-gradient(160deg,#ffd9a8,#f39a7a)]">
                <Portrait />
              </div>
            </GroupBox>
            <GroupBox label="Microphone" icon={<Mic className="size-13" strokeWidth={2} />}>
              <PopUp value="MacBook Pro Microphone (Default)" />
              <span className="mt-8 block h-6 overflow-hidden rounded-full bg-white/10">
                <span className="block h-full w-[46%] rounded-full bg-[#34c759]" />
              </span>
            </GroupBox>
            <GroupBox
              label="Options"
              icon={<SlidersHorizontal className="size-13" strokeWidth={2} />}
            >
              <div className="space-y-8 ui-text-13">
                <p className="flex items-center justify-between">
                  System Audio
                  <Toggle on />
                </p>
                <p className="flex items-center justify-between">
                  Custom Cursor
                  <Toggle on />
                </p>
                <p className="ui-text-11 leading-[1.35] text-ui-fg-2">
                  Hides the system cursor; the editor draws a smooth one from the recorded pointer.
                </p>
                <p className="flex items-center gap-6">
                  <ChevronRight className="size-12 text-ui-fg-2" strokeWidth={2.5} />
                  Advanced
                </p>
              </div>
            </GroupBox>
          </div>
        </div>
        <div className="absolute inset-x-20 bottom-20">
          <AppButton
            kind="record"
            large
            className="w-full"
            icon={<CircleDot className="size-16" strokeWidth={2.4} />}
          >
            Start Recording
          </AppButton>
        </div>
      </MacWindow>
    </AppFrame>
  );
}

/** The source preview: a still of the display, wallpaper and all, with the app being recorded. */
function DesktopStill() {
  return (
    <div className="relative aspect-[16/10] h-full overflow-hidden ui-rounded-4 bg-[radial-gradient(80%_90%_at_20%_10%,#ffc23a_0%,transparent_60%),linear-gradient(135deg,#ff8a5c,#f0668f_35%,#7b3fd6_70%,#2f46e8)]">
      <span className="absolute inset-x-0 top-0 h-[4%] bg-white/45" />
      <div className="absolute top-[13%] left-[12%] aspect-[16/10] w-[76%] overflow-hidden ui-rounded-4 shadow-[0_4px_12px_rgb(10_8_40/0.4)]">
        <div className="@container absolute inset-0">
          <DemoRecording cursorLarge={false} />
        </div>
      </div>
    </div>
  );
}

/** The Export sheet with its options showing (ExportSheet.swift). */
export function ExportSheetWindow({ className }: { className?: string }) {
  const rows: { label: string; control: ReactNode }[] = [
    { label: "Format", control: <PopUp value="H.264" /> },
    {
      label: "Quality",
      control: (
        <Segmented options={["Low", "Medium", "High", "Maximum"]} selected="High" width={250} />
      ),
    },
    {
      label: "Frame rate",
      control: <Segmented options={["24 fps", "30 fps", "60 fps"]} selected="30 fps" width={190} />,
    },
    {
      label: "Resolution",
      control: <Segmented options={["100%", "75%", "50%"]} selected="100%" width={190} />,
    },
    { label: "Include audio", control: <Toggle on /> },
  ];

  return (
    <AppFrame width={480} height={418} className={className}>
      <div className="absolute inset-0 overflow-hidden ui-rounded-14 bg-ui-window shadow-[0_0_0_1px_rgb(255_255_255/0.1),0_3cqw_7cqw_-1cqw_rgb(4_6_20/0.6)]">
        <div className="flex items-center gap-10 px-20 py-14">
          <span className="grid size-32 place-items-center ui-rounded-8 bg-ui-accent text-ui-on-accent shadow-[0_3px_8px_rgb(61_220_151/0.3)]">
            <Share className="size-15" strokeWidth={2.4} />
          </span>
          <span className="leading-[1.25]">
            <span className="block ui-text-17 font-bold">Export</span>
            <span className="block ui-text-11 text-ui-fg-2">Launchpad onboarding tour</span>
          </span>
        </div>
        <div className="h-px bg-white/8" />
        <div className="p-20">
          <Segmented
            options={["Web", "Smooth", "Compact", "Master", "GIF"]}
            selected="Web"
            width={440}
          />
          <p className="mt-6 ui-text-10 text-ui-fg-2">H.264 · up to 1080p · 30 fps</p>

          <div className="mt-16 space-y-10 ui-text-13">
            {rows.map((row) => (
              <div key={row.label} className="flex items-center gap-10">
                <span className="w-96 shrink-0 text-right">{row.label}</span>
                {row.control}
              </div>
            ))}
          </div>

          <div className="mt-16 space-y-4 ui-rounded-8 border border-white/8 bg-ui-stage p-12 ui-text-12">
            <p className="flex justify-between">
              Output
              <span className="tabular-nums">1920 × 1080 · 30 fps · H.264 .mp4</span>
            </p>
            <p className="flex justify-between">
              Estimated size
              <span className="tabular-nums">≈ 14 MB</span>
            </p>
          </div>

          <div className="mt-16 flex justify-end gap-8">
            <AppButton>Cancel</AppButton>
            <AppButton kind="primary">Export…</AppButton>
          </div>
        </div>
      </div>
    </AppFrame>
  );
}

/** The editor's transport bar and timeline, close up, as on the Edit step. */
export function TimelineWindow({ className }: { className?: string }) {
  return (
    <AppFrame width={952} height={303} className={className}>
      <div className="absolute inset-0 flex flex-col gap-8 ui-rounded-14 bg-ui-window p-8 shadow-[0_0_0_1px_rgb(255_255_255/0.1)]">
        <TimelineCloseUp />
      </div>
    </AppFrame>
  );
}

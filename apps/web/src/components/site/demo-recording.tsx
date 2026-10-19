import { Bell, Check, Inbox, Link, ListTodo, Search } from "lucide-react";

import { recordingAt } from "@/components/site/editor-demo-script";
import { cn } from "@/lib/utils";

/*
 * The screen recording playing in the hero editor's preview: a window capture of a made-up project app.
 * It's drawn in units of a 1000 × 625 recording (`ui-units` against the recording's own container). The
 * parts the clock drives are tagged `data-el`; editor-demo.tsx moves the cursor and sets `data-on`.
 */

const tasks = [
  { label: "Write the welcome email", who: "PS", due: "Mon", done: true },
  { label: "Record the product tour", who: "SL", due: "Wed", done: false, ticked: true },
  { label: "Review pricing page copy", who: "AM", due: "Wed", done: true },
  { label: "Translate help articles", who: "PS", due: "Thu", done: false },
  { label: "Schedule the launch email", who: "SL", due: "Fri", done: true },
];

const avatarTint: Record<string, string> = {
  PS: "bg-[#f0668f]",
  SL: "bg-[#16876f]",
  AM: "bg-[#2f46e8]",
};

export function DemoRecording({ cursorLarge, time = 0 }: { cursorLarge: boolean; time?: number }) {
  const snapshot = recordingAt(time);
  return (
    <div className="absolute inset-0 bg-white ui-text-13 text-[#23263f] [--ui-width:1000] ui-units">
      <div
        data-el="camera"
        className="absolute inset-0 will-change-transform"
        style={{
          transform: `scale(${snapshot.camera.scale})`,
          transformOrigin: `${snapshot.camera.origin[0]}% ${snapshot.camera.origin[1]}%`,
        }}
      >
        <TitleBar />
        <Sidebar />
        <Main on={snapshot.on} />
        <SharePopover on={snapshot.on} />
        <ClickRing />
        <Cursor large={cursorLarge} at={snapshot.cursor} />
      </div>
    </div>
  );
}

function TitleBar() {
  return (
    <div className="absolute inset-x-0 top-0 flex h-44 items-center border-b border-[#e7e8ee] bg-[#f7f7fa] px-16">
      <span className="flex gap-8">
        <span className="size-12 rounded-full bg-[#ff5f57]" />
        <span className="size-12 rounded-full bg-[#febc2e]" />
        <span className="size-12 rounded-full bg-[#28c840]" />
      </span>
      <span className="ml-24 font-semibold">Launchpad</span>
      <span className="ml-auto flex h-26 w-220 items-center gap-8 ui-rounded-7 bg-[#ebecf1] px-10 text-[#8a8ea3]">
        <Search className="size-13" strokeWidth={2.2} />
        Search
      </span>
      <span className="ml-14 flex -space-x-6">
        {["PS", "SL", "AM"].map((who) => (
          <span
            key={who}
            className={cn(
              "grid size-24 place-items-center rounded-full border-2 border-[#f7f7fa] ui-text-9 font-semibold text-white",
              avatarTint[who],
            )}
          >
            {who}
          </span>
        ))}
      </span>
      <span className="ml-14 grid h-26 w-76 place-items-center ui-rounded-7 bg-[#2f46e8] font-semibold text-white">
        Share
      </span>
    </div>
  );
}

function Sidebar() {
  const projects = ["Onboarding", "Billing revamp", "Mobile beta", "Help centre"];
  return (
    <div className="absolute top-44 bottom-0 left-0 w-200 border-r border-[#e7e8ee] bg-[#f4f5f8] px-14 py-18 text-[#555a74]">
      <p className="flex items-center gap-10 px-8 py-6">
        <Inbox className="size-15" strokeWidth={2} />
        Inbox
        <span className="ml-auto ui-rounded-5 bg-[#e1e3ec] px-6 ui-text-11 font-semibold">4</span>
      </p>
      <p className="flex items-center gap-10 px-8 py-6">
        <ListTodo className="size-15" strokeWidth={2} />
        My tasks
      </p>
      <p className="flex items-center gap-10 px-8 py-6">
        <Bell className="size-15" strokeWidth={2} />
        Updates
      </p>
      <p className="mt-22 px-8 pb-6 ui-text-11 font-semibold tracking-wide text-[#9a9eb3] uppercase">
        Projects
      </p>
      {projects.map((name, i) => (
        <p
          key={name}
          className={cn(
            "flex items-center gap-10 ui-rounded-7 px-8 py-6",
            i === 0 && "bg-[#e3e6fb] font-medium text-[#2f46e8]",
          )}
        >
          <span
            className={cn(
              "size-9 rounded-full",
              ["bg-[#2f46e8]", "bg-[#ffc23a]", "bg-[#16876f]", "bg-[#f0668f]"][i],
            )}
          />
          {name}
        </p>
      ))}
    </div>
  );
}

type RecordingState = ReturnType<typeof recordingAt>["on"];

function Main({ on }: { on: RecordingState }) {
  return (
    <div className="absolute top-44 right-0 bottom-0 left-200 px-40 pt-34">
      <p className="ui-text-12 font-medium text-[#8a8ea3]">Projects / Onboarding</p>
      <p className="mt-6 ui-text-26 font-semibold tracking-tight">Onboarding launch</p>
      <div className="mt-14 flex items-center gap-14 text-[#6b6f86]">
        <span className="relative h-6 w-260 overflow-hidden rounded-full bg-[#e9eaf0]">
          <span
            data-el="progress"
            data-on={on["progress"] ? "" : undefined}
            className="absolute inset-y-0 left-0 w-[60%] rounded-full bg-[#16876f] transition-[width] duration-500 data-on:w-[80%]"
          />
        </span>
        <span className="relative ui-text-12 whitespace-nowrap">
          <span
            data-el="progress-text"
            data-on={on["progress-text"] ? "" : undefined}
            className="data-on:opacity-0"
          >
            3 of 5 done
          </span>
          <span
            data-el="progress-text-done"
            data-on={on["progress-text-done"] ? "" : undefined}
            className="absolute left-0 opacity-0 data-on:opacity-100"
          >
            4 of 5 done
          </span>
        </span>
        <span className="ml-auto ui-text-12">Due Friday</span>
      </div>

      <div className="mt-22 space-y-10">
        {tasks.map((task) => (
          <div
            key={task.label}
            className="flex h-52 items-center gap-14 ui-rounded-10 border border-[#e7e8ee] px-16 ui-text-15"
          >
            <span
              className={cn(
                "relative grid size-20 shrink-0 place-items-center ui-rounded-6 border-2",
                task.done ? "border-[#16876f] bg-[#16876f] text-white" : "border-[#b9bdcc]",
              )}
            >
              {task.done && <Check className="size-13" strokeWidth={3.2} />}
              {task.ticked && (
                <span
                  data-el="ticked"
                  data-on={on["ticked"] ? "" : undefined}
                  className="absolute -inset-2 grid place-items-center ui-rounded-6 bg-[#16876f] text-white opacity-0 transition-opacity duration-150 data-on:opacity-100"
                >
                  <Check className="size-13" strokeWidth={3.2} />
                </span>
              )}
            </span>
            <span className={cn(task.done && "text-[#8a8ea3] line-through decoration-[#c4c7d4]")}>
              {task.label}
            </span>
            <span className="ml-auto ui-text-12 text-[#8a8ea3]">{task.due}</span>
            <span
              className={cn(
                "grid size-24 place-items-center rounded-full ui-text-9 font-semibold text-white",
                avatarTint[task.who],
              )}
            >
              {task.who}
            </span>
          </div>
        ))}
      </div>

      <div className="absolute inset-x-40 bottom-24 flex items-center">
        <span className="ui-text-12 text-[#8a8ea3]">Edited 2 minutes ago</span>
        <span className="relative ml-auto grid h-40 w-170 place-items-center ui-rounded-10 bg-[#2f46e8] ui-text-14 font-semibold text-white">
          Publish changes
          <span
            data-el="published"
            data-on={on["published"] ? "" : undefined}
            className="absolute inset-0 flex items-center justify-center gap-8 ui-rounded-10 bg-[#16876f] opacity-0 transition-opacity duration-150 data-on:opacity-100"
          >
            <Check className="size-15" strokeWidth={3} />
            Published
          </span>
        </span>
      </div>
    </div>
  );
}

function SharePopover({ on }: { on: RecordingState }) {
  const people = [
    { who: "PS", name: "Priya Shah", role: "Owner" },
    { who: "SL", name: "Sam Lee", role: "Can edit" },
  ];
  return (
    <div
      data-el="popover"
      data-on={on["popover"] ? "" : undefined}
      className="absolute top-52 right-16 w-310 origin-top-right scale-95 ui-rounded-12 border border-[#e3e4ea] bg-white p-16 opacity-0 shadow-[0_12px_32px_-8px_rgb(20_24_60/0.3)] transition-[opacity,scale] duration-150 data-on:scale-100 data-on:opacity-100"
    >
      <p className="ui-text-14 font-semibold">Share “Onboarding launch”</p>
      <div className="mt-12 flex gap-8">
        <span className="flex h-32 flex-1 items-center ui-rounded-8 border border-[#d6d8e2] px-10">
          <span
            data-el="email"
            data-on={on["email"] ? "" : undefined}
            className="transition-[filter] duration-150 data-on:blur-[3px]"
          >
            alex.morgan@launchpad.dev
          </span>
        </span>
        <span className="grid h-32 place-items-center ui-rounded-8 bg-[#2f46e8] px-12 font-semibold text-white">
          Invite
        </span>
      </div>
      {people.map((p) => (
        <div key={p.who} className="mt-12 flex items-center gap-10">
          <span
            className={cn(
              "grid size-26 place-items-center rounded-full ui-text-10 font-semibold text-white",
              avatarTint[p.who],
            )}
          >
            {p.who}
          </span>
          {p.name}
          <span className="ml-auto ui-text-12 text-[#8a8ea3]">{p.role}</span>
        </div>
      ))}
      <p className="mt-14 flex items-center gap-6 border-t border-[#ececf2] pt-12 ui-text-12 font-medium text-[#2f46e8]">
        <Link className="size-13" strokeWidth={2.2} />
        Copy link
      </p>
    </div>
  );
}

/** The editor's click highlight (default colour #3B82F6), drawn where the last click landed. */
function ClickRing() {
  return (
    <span
      data-el="ring"
      className="pointer-events-none absolute size-64 rounded-full border-3 border-[#3b82f6] bg-[#3b82f6]/20 opacity-0"
    />
  );
}

function Cursor({ large, at }: { large: boolean; at: readonly [number, number] }) {
  return (
    <span
      data-el="cursor"
      className="pointer-events-none absolute"
      style={{ left: `${at[0]}%`, top: `${at[1]}%` }}
    >
      {/* The arrow's tip sits at (4, 4) of its 32 px box. */}
      {/* oxlint-disable-next-line nextjs/no-img-element -- tiny static SVG, no optimisation needed */}
      <img
        src="/cursors/arrow.svg"
        alt=""
        data-el="cursor-img"
        className={cn(
          "block w-30 max-w-none origin-[12.5%_12.5%] -translate-x-[12.5%] -translate-y-[12.5%] transition-[scale] duration-300",
          large && "scale-135",
        )}
      />
    </span>
  );
}

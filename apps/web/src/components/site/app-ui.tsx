import { ChevronsUpDown } from "lucide-react";
import type { CSSProperties, ReactNode } from "react";

import { cn } from "@/lib/utils";

/*
 * Building blocks for drawing My Screen Cam's own windows in HTML: the dark "Midnight Glass" theme from
 * apps/macos (AppTheme.swift) and the SwiftUI controls as they render on macOS. Everything inside `AppFrame`
 * is measured in the app's points (see `ui-units` in globals.css), so sizes here are copied from the
 * SwiftUI sources and screenshots of the running app: `h-28` is a 28 pt button at any page width.
 */

/** Scales a `width` × `height` pt drawing to the width of its container. */
export function AppFrame({
  width,
  height,
  className,
  children,
}: {
  width: number;
  height: number;
  className?: string;
  children: ReactNode;
}) {
  return (
    <div
      className={cn("@container w-full", className)}
      style={{ aspectRatio: `${width} / ${height}` }}
    >
      <div
        className="relative size-full leading-[1.25] text-ui-fg antialiased ui-units"
        style={{ "--ui-width": width } as CSSProperties}
      >
        {children}
      </div>
    </div>
  );
}

/** A dark app window with a transparent title bar: traffic lights and the window title. */
export function MacWindow({
  title,
  className,
  children,
}: {
  title: string;
  className?: string;
  children: ReactNode;
}) {
  return (
    <div
      className={cn(
        "absolute inset-0 flex flex-col overflow-hidden ui-rounded-14 bg-ui-window shadow-[0_0_0_1px_rgb(255_255_255/0.1),0_2.5cqw_6cqw_-1cqw_rgb(4_6_20/0.55)]",
        className,
      )}
    >
      <div className="flex h-32 shrink-0 items-center px-9">
        <TrafficLights />
        <span className="ml-26 truncate ui-text-13 font-semibold text-ui-fg-2">{title}</span>
      </div>
      <div className="relative min-h-0 flex-1">{children}</div>
    </div>
  );
}

export function TrafficLights() {
  return (
    <span className="flex gap-10">
      <span className="size-13 rounded-full bg-[#ff5f57]" />
      <span className="size-13 rounded-full bg-[#febc2e]" />
      <span className="size-13 rounded-full bg-[#28c840]" />
    </span>
  );
}

/** A floating panel (`themePanel`): filled, 14 pt corners, hairline border. */
export function Panel({
  className,
  stage,
  children,
}: {
  className?: string;
  stage?: boolean;
  children?: ReactNode;
}) {
  return (
    <div
      className={cn(
        "relative overflow-hidden ui-rounded-14 border border-white/8",
        stage ? "bg-ui-stage" : "bg-ui-panel",
        className,
      )}
    >
      {children}
    </div>
  );
}

/** `ThemeButtonStyle`: 28 pt rounded rectangles, or 40 pt for a window's main action. */
export function AppButton({
  kind = "standard",
  large,
  icon,
  className,
  children,
}: {
  kind?: "standard" | "primary" | "destructive" | "record";
  large?: boolean;
  icon?: ReactNode;
  className?: string;
  children?: ReactNode;
}) {
  const filled = kind === "primary" || kind === "record";
  return (
    <span
      className={cn(
        "inline-flex shrink-0 items-center justify-center whitespace-nowrap",
        large
          ? "h-40 gap-8 ui-rounded-8 px-18 ui-text-15"
          : "h-28 gap-6 ui-rounded-6 px-12 ui-text-13",
        filled ? "font-semibold" : "border border-white/9 bg-white/6 font-medium",
        kind === "standard" && "text-ui-fg",
        kind === "destructive" && "text-ui-destructive",
        kind === "primary" &&
          "bg-ui-accent text-ui-on-accent shadow-[0_4px_9px_-2px_rgb(61_220_151/0.35)]",
        kind === "record" && "bg-ui-record text-white shadow-[0_4px_9px_-2px_rgb(255_77_106/0.35)]",
        className,
      )}
    >
      {icon}
      {children}
    </span>
  );
}

/** A SwiftUI switch in the theme's green. */
export function Toggle({ on, className }: { on: boolean; className?: string }) {
  return (
    <span
      className={cn(
        "relative inline-block h-20 w-40 shrink-0 rounded-full transition-colors duration-200",
        on ? "bg-ui-accent" : "bg-white/12",
        className,
      )}
    >
      <span
        className={cn(
          "absolute top-2 h-16 w-24 rounded-full shadow-[0_1px_2px_rgb(0_0_0/0.35)] transition-[left] duration-200",
          on ? "left-14 bg-[#effff7]" : "left-2 bg-[#e3e5ea]",
        )}
      />
    </span>
  );
}

/**
 * A slider track with a capsule knob. `value` is the position, 0…1, either a number or a CSS expression
 * (the hero animates some through custom properties).
 */
export function SliderTrack({
  value,
  target,
  className,
}: {
  value: number | string;
  target?: string;
  className?: string;
}) {
  const position = typeof value === "number" ? `${value * 100}%` : `calc(${value} * 100%)`;
  return (
    <span data-target={target} className={cn("relative block h-14", className)}>
      <span className="absolute inset-x-0 top-1/2 h-3 -translate-y-1/2 rounded-full bg-white/10" />
      <span
        className="absolute top-1/2 left-0 h-3 -translate-y-1/2 rounded-full bg-ui-accent"
        style={{ width: position }}
      />
      <span
        className="absolute top-1/2 h-13 w-20 -translate-1/2 rounded-full bg-[#eef0f4] shadow-[0_1px_3px_rgb(0_0_0/0.45)]"
        style={{ left: position }}
      />
    </span>
  );
}

/** A segmented picker; the selected segment is filled with the accent, as in the app. */
export function Segmented({
  options,
  selected,
  width,
  target,
  className,
}: {
  options: readonly string[];
  selected: string;
  /** Width in points. */
  width: number;
  target?: string;
  className?: string;
}) {
  return (
    <span
      className={cn("flex h-20 shrink-0 ui-rounded-6 bg-white/7 p-1 ui-text-12", className)}
      style={{ width: `calc(var(--spacing) * ${width})` }}
    >
      {options.map((option) => (
        <span
          key={option}
          data-target={target ? `${target}-${option}` : undefined}
          className={cn(
            "grid flex-1 place-items-center ui-rounded-5 transition-colors duration-150",
            option === selected ? "bg-ui-accent font-medium text-ui-on-accent" : "text-ui-fg-2",
          )}
        >
          {option}
        </span>
      ))}
    </span>
  );
}

/** A pop-up button picker: the value and up/down chevrons. */
export function PopUp({ value, className }: { value: string; className?: string }) {
  return (
    <span
      className={cn(
        "inline-flex h-20 shrink-0 items-center gap-8 ui-rounded-6 border border-white/6 bg-white/8 pr-6 pl-10 ui-text-12",
        className,
      )}
    >
      {value}
      <ChevronsUpDown className="size-9 text-ui-fg-2" strokeWidth={2.5} />
    </span>
  );
}

/** A colour well, drawn as the capsule swatch macOS shows in a grouped form. */
export function ColorWell({ color }: { color: string }) {
  return (
    <span className="inline-block h-17 w-38 rounded-full bg-white/8 p-2">
      <span className="block size-full rounded-full" style={{ background: color }} />
    </span>
  );
}

/** One `Section` of a grouped form: an optional bold header over a rounded box of rows. */
export function FormSection({
  header,
  trailing,
  className,
  children,
}: {
  header?: string;
  trailing?: ReactNode;
  className?: string;
  children: ReactNode;
}) {
  return (
    <div className={cn(header ? "mt-20 first:mt-0" : "mt-10 first:mt-0", className)}>
      {header && (
        <div className="flex items-baseline justify-between px-10 pb-9 ui-text-13 font-bold">
          {header}
          {trailing}
        </div>
      )}
      <div className="ui-rounded-10 bg-ui-section px-10">{children}</div>
    </div>
  );
}

/** A form row: label on the left, control on the right, hairline between rows. */
export function FormRow({
  label,
  className,
  children,
}: {
  label?: ReactNode;
  className?: string;
  children?: ReactNode;
}) {
  return (
    <div
      className={cn(
        "flex min-h-40 items-center justify-between gap-12 border-t border-white/8 ui-text-13 first:border-t-0",
        className,
      )}
    >
      {label !== undefined && <span className="truncate">{label}</span>}
      {children}
    </div>
  );
}

/**
 * `ValueSlider` in a grouped form: the title and value on one line, the slider below on the right.
 * `valueId` names a value the hero rewrites as it animates.
 */
export function SliderRow({
  title,
  value,
  position,
  valueId,
  target,
}: {
  title: string;
  value: string;
  position: number | string;
  valueId?: string;
  target?: string;
}) {
  return (
    <div className="border-t border-white/8 pt-9 pb-8 first:border-t-0">
      <div className="flex justify-between ui-text-11.5">
        <span>{title}</span>
        <span data-value={valueId} className="text-ui-fg-2 tabular-nums">
          {value}
        </span>
      </div>
      <SliderTrack value={position} target={target} className="mt-4 ml-[45%]" />
    </div>
  );
}

/** A thin overlay scroller thumb, for panels whose form runs past the bottom. */
export function ScrollThumb({ top = 0, height }: { top?: number; height: number }) {
  return (
    <span
      className="absolute right-4 w-6 rounded-full bg-white/30"
      style={{
        top: `calc(var(--spacing) * ${top})`,
        height: `calc(var(--spacing) * ${height})`,
      }}
    />
  );
}

/* SF Symbols that lucide doesn't draw closely enough. */

/** `gobackward.5` / `goforward.5`. */
export function SkipIcon({ forward, className }: { forward?: boolean; className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className={className}
      fill="none"
      stroke="currentColor"
      strokeWidth={1.7}
      strokeLinecap="round"
      strokeLinejoin="round"
      style={forward ? { transform: "scaleX(-1)" } : undefined}
    >
      <path d="M8.2 4.6A9 9 0 1 1 3.4 10" />
      <path d="M8.6 1.6 8.2 4.6l3 1" />
      <text
        x="12"
        y="16.2"
        textAnchor="middle"
        fontSize="9"
        fontWeight="700"
        fill="currentColor"
        stroke="none"
        style={forward ? { transform: "scaleX(-1)", transformOrigin: "12px 12px" } : undefined}
      >
        5
      </text>
    </svg>
  );
}

/** `drop.halffull`. */
export function DropHalfIcon({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className={className}
      fill="none"
      stroke="currentColor"
      strokeWidth={1.8}
    >
      <path d="M12 3.2c3.2 4.1 6 7.4 6 10.9a6 6 0 0 1-12 0c0-3.5 2.8-6.8 6-10.9Z" />
      <path d="M6.2 14.4h11.6a6 6 0 0 1-11.6 0Z" fill="currentColor" stroke="none" />
    </svg>
  );
}

/** `cursorarrow`. */
export function CursorArrowIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className}>
      <path d="M6.5 3.5v15.2l4-3.9 2.6 5.6 2.4-1.1-2.6-5.5 5.6-.3Z" fill="currentColor" />
    </svg>
  );
}

/** `rectangle.inset.filled`. */
export function RectangleInsetIcon({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className={className}
      fill="none"
      stroke="currentColor"
      strokeWidth={1.7}
    >
      <rect x="2.5" y="5" width="19" height="14" rx="2.6" />
      <rect x="5.5" y="8" width="13" height="8" rx="1" fill="currentColor" stroke="none" />
    </svg>
  );
}

/** `captions.bubble`. */
export function CaptionsBubbleIcon({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className={className}
      fill="none"
      stroke="currentColor"
      strokeWidth={1.7}
      strokeLinecap="round"
    >
      <path d="M5 4h14a2.5 2.5 0 0 1 2.5 2.5v8A2.5 2.5 0 0 1 19 17h-8l-4.5 3.5V17H5a2.5 2.5 0 0 1-2.5-2.5v-8A2.5 2.5 0 0 1 5 4Z" />
      <path d="M7 9.2h4M13.5 9.2H17M7 12.4h6.5M15.8 12.4H17" />
    </svg>
  );
}

/** `arrow.uturn.backward.square`. */
export function ResetCutsIcon({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className={className}
      fill="none"
      stroke="currentColor"
      strokeWidth={1.7}
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <rect x="3.5" y="3.5" width="17" height="17" rx="3.5" />
      <path d="M9.5 9 7.5 11l2 2" />
      <path d="M7.8 11h5.4a3 3 0 0 1 0 6H11" />
    </svg>
  );
}

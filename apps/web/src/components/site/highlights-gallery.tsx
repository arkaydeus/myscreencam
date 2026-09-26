"use client";

import { ChevronLeft, ChevronRight } from "lucide-react";
import { useEffect, useRef, useState } from "react";

/**
 * A horizontal row of highlight cards that scrolls natively (swipe, trackpad, keyboard) and snaps to each
 * card. The paddle buttons below it page through the row on wider screens.
 */
export function HighlightsGallery({ children }: { children: React.ReactNode }) {
  const scroller = useRef<HTMLUListElement>(null);
  const [edges, setEdges] = useState({ start: true, end: false });

  useEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const update = () =>
      setEdges({
        start: el.scrollLeft <= 1,
        end: el.scrollLeft + el.clientWidth >= el.scrollWidth - 1,
      });
    update();
    el.addEventListener("scroll", update, { passive: true });
    window.addEventListener("resize", update);
    return () => {
      el.removeEventListener("scroll", update);
      window.removeEventListener("resize", update);
    };
  }, []);

  const page = (direction: 1 | -1) => {
    const el = scroller.current;
    if (!el) return;
    const card = el.firstElementChild?.getBoundingClientRect().width ?? 400;
    el.scrollBy({ left: direction * (card + 20), behavior: "smooth" });
  };

  return (
    <>
      <ul
        ref={scroller}
        aria-label="Highlights"
        className="mt-7 flex snap-x snap-mandatory gallery-inset [scrollbar-width:none] gap-3 overflow-x-auto overscroll-x-contain sm:mt-12 sm:gap-5 [&::-webkit-scrollbar]:hidden"
      >
        {children}
      </ul>
      <div className="page-width mt-7 hidden justify-end gap-4 sm:flex">
        <PaddleButton label="Previous highlights" disabled={edges.start} onClick={() => page(-1)}>
          <ChevronLeft aria-hidden className="size-5" strokeWidth={2.25} />
        </PaddleButton>
        <PaddleButton label="Next highlights" disabled={edges.end} onClick={() => page(1)}>
          <ChevronRight aria-hidden className="size-5" strokeWidth={2.25} />
        </PaddleButton>
      </div>
    </>
  );
}

function PaddleButton({
  label,
  disabled,
  onClick,
  children,
}: {
  label: string;
  disabled: boolean;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      aria-label={label}
      disabled={disabled}
      onClick={onClick}
      className="grid size-11 place-items-center rounded-full bg-[#e3e3e8] text-ink transition-[background-color,opacity] outline-none hover:bg-[#dadade] focus-visible:ring-3 focus-visible:ring-ring/50 disabled:cursor-default disabled:opacity-40"
    >
      {children}
    </button>
  );
}

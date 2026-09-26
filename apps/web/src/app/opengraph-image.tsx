import { ImageResponse } from "next/og";

import { site } from "@/lib/site";

export const alt = `${site.name}: screen recordings that look finished`;
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

/** A recording framed on the painted canvas, with the headline on it. */
export default function OpengraphImage() {
  return new ImageResponse(
    <div
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        padding: 72,
        background:
          "radial-gradient(60% 80% at 12% 18%, #ffc23a 0%, transparent 60%), radial-gradient(55% 70% at 88% 12%, #f0668f 0%, transparent 62%), radial-gradient(70% 90% at 78% 96%, #16876f 0%, transparent 60%), linear-gradient(135deg, #2f46e8, #5b3fd6)",
      }}
    >
      <div
        style={{
          flex: 1,
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          padding: 64,
          borderRadius: 28,
          background: "#ffffff",
          color: "#1b1e45",
          boxShadow: "0 30px 80px rgba(20, 16, 70, 0.5)",
        }}
      >
        <div style={{ fontSize: 34, fontWeight: 700 }}>{site.name}</div>
        <div style={{ fontSize: 84, fontWeight: 800, lineHeight: 1, letterSpacing: -3 }}>
          Screen recordings that look finished.
        </div>
      </div>
    </div>,
    size,
  );
}

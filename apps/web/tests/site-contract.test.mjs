import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { DownloadButton } from "../src/components/site/brand";
import { SiteFooter } from "../src/components/site/closing";
import { EditorDemo } from "../src/components/site/editor-demo";
import {
  LOOP,
  blurMask,
  cameraAt,
  clicks,
  narration,
  script,
  zoomEnd,
  zooms,
} from "../src/components/site/editor-demo-script";
import {
  ANNOTATE_TIME,
  ANNOTATE_WORD,
  SubtitlesWindow,
} from "../src/components/site/subtitles-window";
import { recordingAt } from "../src/components/site/editor-demo-script";
import { site } from "../src/lib/site";

const css = readFileSync(resolve(import.meta.dir, "../src/app/globals.css"), "utf8");

const srgbToLinear = (channel) =>
  channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;

test("source link points at the intended GitHub repository", () => {
  expect(site.sourceUrl).toBe("https://github.com/arkaydeus/myscreencam");
});

test("hero text gradient meets 4.5:1 against white at stops and between them", () => {
  const paint = css.match(/@utility text-paint \{([^}]+)\}/)?.[1];
  expect(paint).toContain("in srgb");
  const stops = Array.from(paint.matchAll(/#([0-9a-f]{6})\b/gi), ([, hex]) =>
    [0, 2, 4].map((offset) => parseInt(hex.slice(offset, offset + 2), 16) / 255),
  );
  expect(stops).toHaveLength(4);
  for (let stop = 1; stop < stops.length; stop++) {
    for (let sample = 0; sample <= 100; sample++) {
      const rgb = stops[stop - 1].map(
        (channel, i) => channel + (stops[stop][i] - channel) * (sample / 100),
      );
      const luminance = rgb.reduce(
        (sum, channel, i) => sum + srgbToLinear(channel) * [0.2126, 0.7152, 0.0722][i],
        0,
      );
      expect(1.05 / (luminance + 0.05)).toBeGreaterThanOrEqual(4.5);
    }
  }
});

test("Download for Mac points at the stable DMG asset", () => {
  const download = renderToStaticMarkup(createElement(DownloadButton));

  expect(site.downloadUrl).toMatch(/\/releases\/latest\/download\/MyScreenCam\.dmg$/);
  expect(download).toContain(`href="${site.downloadUrl}"`);
  expect(download).toContain("Download for Mac");
});

test("footer preserves the performance footnote and Releases, GitHub, FAQ and download links", () => {
  const footer = renderToStaticMarkup(createElement(SiteFooter));
  const links = Array.from(
    footer.matchAll(/<a href="([^"]+)"[^>]*>([^<]+)<\/a>/g),
    ([, href, label]) => [label, href],
  );

  expect(footer).toContain('<li id="footnote-1">');
  for (const [label, href] of [
    ["Releases", site.releasesUrl],
    ["GitHub", site.sourceUrl],
    ["FAQ", "#faq"],
    ["Download", site.downloadUrl],
  ]) {
    expect(links).toContainEqual([label, href]);
  }
});

test("hero zooms fit the loop and every click but the last lands inside a zoom", () => {
  for (const [i, z] of zooms.entries()) {
    expect(z.start).toBeGreaterThan(i === 0 ? 0 : zoomEnd(zooms[i - 1]));
    expect(zoomEnd(z)).toBeLessThan(LOOP);
    expect(cameraAt(z.start).scale).toBe(1);
    expect(cameraAt(z.start + z.easeIn + z.hold / 2).scale).toBe(z.scale);
    expect(cameraAt(zoomEnd(z) + 0.01).scale).toBe(1);
  }
  for (const c of clicks.slice(0, -1)) {
    expect(zooms.some((z) => c >= z.start && c <= zoomEnd(z))).toBe(true);
  }
  expect(blurMask.end).toBeLessThan(LOOP);
});

test("hero timeline draws a block per zoom and a marker per click", () => {
  const demo = renderToStaticMarkup(createElement(EditorDemo));
  const lane = 936 - 78 - 14;

  for (const z of zooms) expect(demo).toContain(`d="M${(z.start / LOOP) * lane} `);
  for (const c of clicks) expect(demo).toContain(`cx="${(c / LOOP) * lane}"`);
  for (const tab of ["zoom", "webcam", "audio", "blur", "cursor", "background", "subtitles"]) {
    expect(demo).toContain(`data-target="tab-${tab}"`);
  }
});

test("the pointer's script runs in order inside one loop, one action at a time", () => {
  let busyUntil = 0;
  for (const step of script) {
    expect(step.at).toBeGreaterThanOrEqual(busyUntil);
    expect(step.at).toBeLessThan(LOOP);
    busyUntil = step.at + ("dur" in step ? step.dur : 0);
  }
  expect(busyUntil).toBeLessThanOrEqual(LOOP);
});

test("subtitle cues are in order, inside the loop and clear of each other", () => {
  for (const [i, cue] of narration.entries()) {
    expect(cue.end).toBeGreaterThan(cue.start);
    expect(cue.start).toBeGreaterThan(i === 0 ? 0 : narration[i - 1].end);
    expect(cue.end).toBeLessThan(LOOP);
  }
});

test("reduced motion stops smooth scrolling", () => {
  const reducedMotion = css.split("@media (prefers-reduced-motion: reduce) {")[1];
  expect(reducedMotion).toMatch(/html\s*\{\s*scroll-behavior: auto;/);
});

test("Annotate uses the recording snapshot and highlighted narration at its playhead", () => {
  const cue = narration.find((entry) => ANNOTATE_TIME >= entry.start && ANNOTATE_TIME < entry.end);
  expect(cue).toBeDefined();
  expect(cue.text.split(" ")).toContain(ANNOTATE_WORD);
  const markup = renderToStaticMarkup(createElement(SubtitlesWindow));
  const snapshot = recordingAt(ANNOTATE_TIME);
  for (const name of ["published", "ticked", "progress", "progress-text", "progress-text-done"]) {
    expect(snapshot.on[name]).toBe(true);
    expect(markup).toContain(`data-el="${name}" data-on=""`);
  }
  expect(markup).toContain("4 of 5 done");
  expect(markup).toContain(`left:${snapshot.cursor[0]}%;top:${snapshot.cursor[1]}%`);
  expect(markup).toContain(`transform:scale(${snapshot.camera.scale})`);
  expect(markup).toContain(
    `transform-origin:${snapshot.camera.origin[0]}% ${snapshot.camera.origin[1]}%`,
  );
  expect(markup).toContain(`>${ANNOTATE_WORD}</span>`);
  expect(markup).toContain("0:13.20");
});

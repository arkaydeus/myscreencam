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
  script,
  zoomEnd,
  zooms,
} from "../src/components/site/editor-demo-script";
import { site } from "../src/lib/site";

const css = readFileSync(resolve(import.meta.dir, "../src/app/globals.css"), "utf8");
const demoSource = readFileSync(
  resolve(import.meta.dir, "../src/components/site/editor-demo.tsx"),
  "utf8",
);

test("Download for Mac points at the stable DMG asset while Releases opens the release page", () => {
  const download = renderToStaticMarkup(createElement(DownloadButton));
  const footer = renderToStaticMarkup(createElement(SiteFooter));

  expect(site.downloadUrl).toMatch(/\/releases\/latest\/download\/MyScreenCam\.dmg$/);
  expect(download).toContain(`href="${site.downloadUrl}"`);
  expect(download).toContain("Download for Mac");
  expect(footer).toContain(`href="${site.releasesUrl}"`);
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
  for (const tab of ["zoom", "webcam", "audio", "cursor", "background"]) {
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

test("reduced motion stops smooth scrolling and the hero loop", () => {
  const reducedMotion = css.split("@media (prefers-reduced-motion: reduce) {")[1];
  expect(reducedMotion).toMatch(/html\s*\{\s*scroll-behavior: auto;/);
  expect(demoSource).toContain('matchMedia("(prefers-reduced-motion: reduce)")');
});

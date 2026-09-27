import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { DownloadButton } from "../src/components/site/brand";
import { CanvasDemo } from "../src/components/site/canvas-demo";
import { SiteFooter } from "../src/components/site/closing";
import { site } from "../src/lib/site";

const css = readFileSync(resolve(import.meta.dir, "../src/app/globals.css"), "utf8");

function keyframes(name) {
  return css.match(new RegExp(`@keyframes ${name} \\{([\\s\\S]*?)\\n\\}`))?.[1];
}

test("Download for Mac points at the stable DMG asset while Releases opens the release page", () => {
  const download = renderToStaticMarkup(createElement(DownloadButton));
  const footer = renderToStaticMarkup(createElement(SiteFooter));

  expect(site.downloadUrl).toMatch(/\/releases\/latest\/download\/MyScreenCam\.dmg$/);
  expect(download).toContain(`href="${site.downloadUrl}"`);
  expect(download).toContain("Download for Mac");
  expect(footer).toContain(`href="${site.releasesUrl}"`);
});

test("hero timeline matches the camera and click keyframes over one 12 second loop", () => {
  const demo = renderToStaticMarkup(createElement(CanvasDemo));
  const camera = keyframes("msc-camera");
  const publish = keyframes("msc-click-publish");
  const check = keyframes("msc-click-check");

  expect(demo).toContain("left:14%;width:42%");
  expect(demo).toContain("left:73%;width:25%");
  expect(demo).toContain("left:13.5%");
  expect(demo).toContain("left:72.5%");
  expect(camera).toMatch(/14%\s*\{\s*transform: scale\(1\)/);
  expect(camera).toMatch(/56%,\s*64%\s*\{\s*transform: scale\(1\)/);
  expect(camera).toMatch(/73%\s*\{\s*transform: scale\(1\)/);
  expect(camera).toMatch(/98%,\s*100%\s*\{\s*transform: scale\(1\)/);
  expect(publish).toMatch(/13\.5%\s*\{\s*opacity: 0\.95/);
  expect(check).toMatch(/72\.5%\s*\{\s*opacity: 0\.95/);
  for (const name of ["camera", "cursor", "click-publish", "click-check", "playhead"]) {
    expect(css).toContain(`animation: msc-${name} 12s`);
  }
});

test("reduced motion disables smooth scrolling and the hero loop", () => {
  const reducedMotion = css.split("@media (prefers-reduced-motion: reduce) {")[1];
  expect(reducedMotion).toMatch(/html\s*\{\s*scroll-behavior: auto;/);
  expect(reducedMotion).toMatch(/\.demo-camera,[\s\S]*?animation: none;/);
});

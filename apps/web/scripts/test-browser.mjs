import assert from "node:assert/strict";
import { chromium } from "playwright";
import { dragged, LOOP, REST, script } from "../src/components/site/editor-demo-script";
import { site } from "../src/lib/site";

// Exercise the production page, including its real CSS and React inspector updates.
const reservation = Bun.serve({ port: 0, fetch: () => new Response() });
const port = reservation.port;
reservation.stop(true);
const url = `http://127.0.0.1:${port}`;
const server = Bun.spawn(
  [
    "mise",
    "exec",
    "--",
    "bun",
    "node_modules/next/dist/bin/next",
    "start",
    "--hostname",
    "127.0.0.1",
    "--port",
    String(port),
  ],
  {
    cwd: import.meta.dir + "/..",
    stdout: "ignore",
    stderr: "inherit",
  },
);
let browser;
try {
  let ready = false;
  for (let attempt = 0; attempt < 200; attempt++) {
    try {
      ready = (await fetch(url)).ok;
    } catch {
      /* Server is still starting. */
    }
    if (ready) break;
    if (server.exitCode !== null) throw new Error("Production server exited before becoming ready");
    await Bun.sleep(50);
  }
  assert(ready, "Production server must start");
  browser = await chromium.launch();
  for (const width of [1440, 1024, 768, 640, 390, 320]) {
    const page = await browser.newPage({ viewport: { width, height: 1000 } });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.addInitScript(() => {
      let id = 0;
      const frames = new Map();
      window.requestAnimationFrame = (callback) => {
        frames.set(++id, callback);
        return id;
      };
      window.cancelAnimationFrame = (key) => frames.delete(key);
      window.demoClock = {
        now: 0,
        tick() {
          this.now += 50;
          const pending = [...frames.values()];
          frames.clear();
          for (const callback of pending) callback(this.now);
        },
      };
      const NativeObserver = window.IntersectionObserver;
      window.IntersectionObserver = class extends NativeObserver {
        constructor(callback, options) {
          super(callback, options);
          this.callback = callback;
        }
        observe(root) {
          if (root.querySelector('[data-el="pointer"]')) {
            // Keep layout tests independent of screenshots/scrolling. Visibility
            // pause/resume and cleanup are exercised by the runtime tests.
            window.demoClock.showHero = () => this.callback([{ isIntersecting: true }]);
          } else super.observe(root);
        }
      };
    });
    await page.goto(url);
    await page.addStyleTag({ content: "*, *::before, *::after { transition: none !important; }" });
    await page.evaluate(() => document.fonts.ready);

    const header = page.getByRole("banner");
    const source = header.getByRole("link", {
      name: "My Screen Cam on GitHub",
      exact: true,
      includeHidden: true,
    });
    assert.equal(await source.count(), 1, "Header has one accessibly named GitHub link");
    assert.equal(
      await source.getAttribute("href"),
      site.sourceUrl,
      "Header links to the source repository",
    );
    assert.equal(await source.isVisible(), width >= 640, "GitHub action uses the roomy header");
    assert(
      await page
        .getByRole("contentinfo")
        .getByRole("link", { name: "GitHub", exact: true })
        .isVisible(),
      "Footer GitHub link stays available",
    );
    assert(
      await header.getByRole("link", { name: "Download", exact: true }).isVisible(),
      "Header download stays available",
    );
    assert(
      await page.getByText("Free to download. No license keys.", { exact: true }).isVisible(),
      "Hero makes a supported free-download claim",
    );
    assert.doesNotMatch(await page.locator("body").innerText(), /open source|forever/i);

    const headerLayout = await header.evaluate((element) => {
      const brand = element.querySelector('a[href="#top"] span');
      const family = getComputedStyle(brand).fontFamily.split(",")[0].replace(/["']/g, "").trim();
      const row = element.firstElementChild;
      const bounds = row.getBoundingClientRect();
      const style = getComputedStyle(row);
      const left = bounds.left + parseFloat(style.paddingLeft);
      const right = bounds.right - parseFloat(style.paddingRight);
      const links = [...element.querySelectorAll("a")].filter(
        (link) => link.getClientRects().length,
      );
      return {
        fontLoaded:
          /nunito/i.test(family) &&
          [...document.fonts].some(
            (font) => font.family.replace(/["']/g, "") === family && font.status === "loaded",
          ),
        outside: links
          .filter((link) => {
            const rect = link.getBoundingClientRect();
            return rect.left < left - 0.5 || rect.right > right + 0.5;
          })
          .map((link) => link.textContent || link.getAttribute("aria-label")),
        overlap: links.some((link, i) =>
          links.slice(i + 1).some((other) => {
            const a = link.getBoundingClientRect();
            const b = other.getBoundingClientRect();
            return a.left < b.right && a.right > b.left;
          }),
        ),
      };
    });
    assert(headerLayout.fontLoaded, `${width}px: header uses loaded Nunito`);
    assert.deepEqual(
      headerLayout.outside,
      [],
      `${width}px: header controls stay inside content gutters`,
    );
    assert.equal(headerLayout.overlap, false, `${width}px: header controls do not overlap`);

    async function noHorizontalOverflow() {
      const dimensions = await page.evaluate(() => ({
        viewport: document.documentElement.clientWidth,
        content: Math.max(document.documentElement.scrollWidth, document.body.scrollWidth),
      }));
      assert(
        dimensions.content <= dimensions.viewport,
        `${width}px: no horizontal page overflow (${dimensions.content}px)`,
      );
    }
    await noHorizontalOverflow();
    if (process.env.BROWSER_SCREENSHOTS) {
      await page.screenshot({ path: `${process.env.BROWSER_SCREENSHOTS}/hero-${width}.png` });
    }
    // The intermediate widths cover the header's responsive breakpoints; exercise
    // the full illustration and animation suite at the original desktop/mobile sizes.
    if (![1440, 390, 320].includes(width)) {
      assert.deepEqual(errors, [], "No browser errors");
      console.log(`Header bounds and page overflow passed at ${width}px`);
      await page.close();
      continue;
    }

    /** Check all clipping ancestors, in CSS pixels, allowing only subpixel rounding. */
    async function contained(locator, label) {
      assert.equal(await locator.count(), 1, `${label}: one element`);
      const failure = await locator.evaluate((element) => {
        const r = element.getBoundingClientRect();
        if (!r.width || !r.height) return "empty bounds";
        for (let parent = element.parentElement; parent; parent = parent.parentElement) {
          const style = getComputedStyle(parent);
          const b = parent.getBoundingClientRect();
          if (
            /(hidden|clip|auto|scroll)/.test(style.overflowX) &&
            (r.left < b.left - 1 || r.right > b.right + 1)
          )
            return `horizontal clipping by ${parent.className}`;
          if (
            /(hidden|clip|auto|scroll)/.test(style.overflowY) &&
            (r.top < b.top - 1 || r.bottom > b.bottom + 1)
          )
            return `vertical clipping by ${parent.className} (${r.bottom - b.bottom}px below, ${b.top - r.top}px above)`;
        }
        return null;
      });
      assert.equal(failure, null, `${width}px ${label}: ${failure}`);
    }
    for (const text of [
      "1920 × 1080 · 30 fps · H.264 .mp4",
      "≈ 14 MB",
      "Cancel",
      "Export…",
      "Start Recording",
      "Built-in Retina Display",
      "FaceTime HD Camera",
      "MacBook Pro Microphone (Default)",
      "Advanced",
      "Search subtitles",
      "Highlight spoken word",
    ]) {
      await contained(page.getByText(text, { exact: true }), text);
    }
    // Both the selected cue and its visible neighbours should fit the Annotate inspector.
    for (const text of ["0:04.50 – 0:08.90", "0:10.10 – 0:14.60", "0:15.30 – 0:19.90"]) {
      const time = page.getByText(text, { exact: true });
      await contained(time.locator(".."), text);
    }

    if (process.env.BROWSER_SCREENSHOTS) {
      await page.locator("#how").screenshot({
        path: `${process.env.BROWSER_SCREENSHOTS}/site-${width}.png`,
      });
    }
    const hero = page.locator("figure").filter({ has: page.locator('[data-el="pointer"]') });
    await hero.scrollIntoViewIfNeeded();
    await page.waitForFunction(() => Boolean(window.demoClock.showHero), null, { polling: 10 });
    await page.evaluate(() => window.demoClock.showHero());
    // Deliberately deliver a timestamp earlier than update()'s performance.now().
    await page.evaluate(() => {
      window.demoClock.now = -50;
      window.demoClock.tick();
    });
    assert.equal(await hero.locator('[data-el="time"]').textContent(), "0:00.00");
    for (let cycle = 0; cycle < 2; cycle++) {
      const odd = cycle === 1;
      let currentTarget;
      for (let frame = 1; frame <= LOOP * 20; frame++) {
        const t = frame / 20;
        for (const step of script) {
          if (step.kind !== "move" || Math.abs(step.at - t) > 0.001) continue;
          const target = typeof step.to === "function" ? step.to(odd) : step.to;
          currentTarget = target;
          if (target !== REST)
            await contained(hero.locator(`[data-target="${target}"]`), `cycle ${cycle} ${target}`);
        }
        const click = script.find((step) => step.kind === "click" && Math.abs(step.at - t) < 0.001);
        if (click && currentTarget !== REST) {
          const target = hero.locator(`[data-target="${currentTarget}"]`);
          await contained(target, `cycle ${cycle} click ${currentTarget}`);
          const targetBox = await target.boundingBox();
          const pointerBox = await hero.locator('[data-el="pointer"]').boundingBox();
          assert(
            pointerBox.x >= targetBox.x - 1 &&
              pointerBox.x <= targetBox.x + targetBox.width + 1 &&
              pointerBox.y >= targetBox.y - 1 &&
              pointerBox.y <= targetBox.y + targetBox.height + 1,
            `Pointer reaches ${currentTarget} before clicking`,
          );
        }
        await page.evaluate(() => window.demoClock.tick());
        const flippedClick = script.find(
          (step) => step.kind === "click" && step.flip && Math.abs(step.at + 0.1 - t) < 0.001,
        );
        if (flippedClick) {
          assert(
            await hero
              .locator(`[data-target="${currentTarget}"]`)
              .evaluate((element) => element.classList.contains("bg-ui-accent")),
            `Selected ${currentTarget}`,
          );
        }
        const outside = await hero.locator('[data-el="pointer"]').evaluate((pointer) => {
          const root = pointer.parentElement.getBoundingClientRect();
          const p = pointer.getBoundingClientRect();
          return (
            p.left < root.left || p.top < root.top || p.left > root.right || p.top > root.bottom
          );
        });
        assert.equal(outside, false, `${width}px cycle ${cycle} t=${t}: pointer within window`);
      }
      for (const [key, range] of Object.entries(dragged)) {
        const variable = {
          zoomScale: "--zoom-scale",
          padding: "--pad",
          radius: "--rad",
          gain: "--gain",
        }[key];
        const actual = await hero
          .locator('[aria-hidden="true"]')
          .first()
          .evaluate((root, property) => Number(root.style.getPropertyValue(property)), variable);
        assert(
          Math.abs(actual - ((odd ? range.from : range.to) - range.min) / (range.max - range.min)) <
            1e-6,
          `${key} endpoint`,
        );
      }
    }
    await noHorizontalOverflow();
    assert.deepEqual(errors, [], "No browser errors");
    console.log(`Browser bounds and both hero cycles passed at ${width}px`);
    await page.close();
  }
} finally {
  await browser?.close();
  server.kill();
  await server.exited;
}

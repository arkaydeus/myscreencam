import { expect, test } from "bun:test";

import { runDemo } from "../src/components/site/editor-demo";
import { dragged, LOOP } from "../src/components/site/editor-demo-script";

/** Only browser boundaries are faked; runDemo executes its real script and rendering code. */
function withDemo(reduced, check) {
  const frames = new Map();
  const timers = new Map();
  const visibility = new Set();
  const preference = new Set();
  const elements = new Map();
  const updates = [];
  let nextId = 1;
  let now = 1000;
  let intersect;
  let disconnected = false;
  const media = {
    matches: reduced,
    addEventListener: (_, listener) => preference.add(listener),
    removeEventListener: (_, listener) => preference.delete(listener),
  };
  const doc = {
    hidden: false,
    addEventListener: (_, listener) => visibility.add(listener),
    removeEventListener: (_, listener) => visibility.delete(listener),
  };
  const element = (name) => {
    if (!elements.has(name)) {
      const attributes = new Set();
      elements.set(name, {
        style: {
          setProperty(key, value) {
            this[key] = value;
          },
        },
        textContent: "",
        setAttribute: (key) => attributes.add(key),
        removeAttribute: (key) => attributes.delete(key),
        hasAttribute: (key) => attributes.has(key),
        toggleAttribute: (key, on) => (on ? attributes.add(key) : attributes.delete(key)),
        getBoundingClientRect: () => ({ left: 1000, top: 300, width: 200, height: 20 }),
      });
    }
    return elements.get(name);
  };
  const root = {
    style: element("root").style,
    querySelector: (selector) => element(selector.match(/="([^"]+)"/)[1]),
    querySelectorAll: (selector) => [element(selector.match(/="([^"]+)"/)[1])],
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 1280, height: 800 }),
  };
  const globals = {
    window: {
      matchMedia: () => media,
      setTimeout: (callback) => {
        const id = nextId++;
        timers.set(id, callback);
        return id;
      },
      clearTimeout: (id) => timers.delete(id),
    },
    document: doc,
    performance: { now: () => now },
    requestAnimationFrame: (callback) => {
      const id = nextId++;
      frames.set(id, callback);
      return id;
    },
    cancelAnimationFrame: (id) => frames.delete(id),
    IntersectionObserver: class {
      constructor(callback) {
        intersect = callback;
      }
      observe() {}
      disconnect() {
        disconnected = true;
      }
    },
  };
  const originals = Object.fromEntries(
    Object.keys(globals).map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]),
  );
  let ui = {
    tab: "zoom",
    scrolled: false,
    selectedZoom: null,
    webcamAspect: "Wide",
    webcamShape: "Rounded",
    cursorSize: "M",
  };
  const values = Object.fromEntries(
    Object.entries(dragged).map(([key, range]) => [key, range.from]),
  );
  let cleanup;
  try {
    for (const [key, value] of Object.entries(globals))
      Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });
    cleanup = runDemo(root, values, (update) => {
      ui = update(ui);
      updates.push({ ...ui });
    });
    const api = {
      frames,
      timers,
      visibility,
      preference,
      element,
      values,
      updates,
      get ui() {
        return ui;
      },
      get disconnected() {
        return disconnected;
      },
      cleanup: () => cleanup(),
      visible: (isIntersecting) => intersect([{ isIntersecting }]),
      hidden: (hidden) => {
        doc.hidden = hidden;
        for (const listener of visibility) listener();
      },
      reduce: (matches) => {
        media.matches = matches;
        for (const listener of preference) listener();
      },
      frame: (delta = 10, finishTimers = true) => {
        now += delta;
        const pending = [...frames.values()];
        frames.clear();
        for (const callback of pending) callback(now);
        // Feedback timers never drive the script, so finish them independently.
        if (finishTimers) {
          for (const callback of timers.values()) callback();
          timers.clear();
        }
      },
      advance: (seconds) => {
        for (let i = 0; i < Math.round(seconds * 100); i++) api.frame();
      },
    };
    check(api);
  } finally {
    cleanup?.();
    for (const [key, descriptor] of Object.entries(originals)) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
  }
}

test("resume with an earlier rAF timestamp does not wrap or replay any script steps", () => {
  withDemo(false, (demo) => {
    demo.visible(true);
    demo.advance(0.8);
    demo.visible(false);
    const before = demo.updates.length;
    const pointer = demo.element("pointer").style.left;
    demo.visible(true);
    demo.frame(-2);
    expect(demo.updates.length).toBe(before);
    expect(demo.ui.tab).toBe("zoom");
    expect(demo.element("pointer").style.left).toBe(pointer);
    expect(demo.element("time").textContent).toBe("0:00.80");
    demo.advance(0.5);
    expect(demo.ui.selectedZoom).toBe("z1");
  });
});

test("two complete loops flip choices and round-trip every drag without replay at wrap", () => {
  withDemo(false, (demo) => {
    demo.visible(true);
    demo.advance(3.6);
    expect(demo.values.zoomScale).toBeGreaterThan(dragged.zoomScale.from);
    expect(demo.values.zoomScale).toBeLessThan(dragged.zoomScale.to);
    expect(demo.element("pointer").hasAttribute("data-pressed")).toBe(true);
    demo.advance(LOOP - 3.6 - 0.01);
    for (const [key, range] of Object.entries(dragged))
      expect(demo.values[key]).toBeCloseTo(range.to, 6);
    expect(demo.ui).toMatchObject({
      tab: "zoom",
      webcamAspect: "Square",
      webcamShape: "Circle",
      cursorSize: "L",
    });
    const count = demo.updates.length;
    demo.advance(0.02);
    expect(demo.updates.length).toBe(count);
    expect(demo.element("published").hasAttribute("data-on")).toBe(false);
    demo.advance(3.6);
    expect(demo.values.zoomScale).toBeLessThan(dragged.zoomScale.to);
    expect(demo.values.zoomScale).toBeGreaterThan(dragged.zoomScale.from);
    demo.advance(LOOP - 3.6);
    for (const [key, range] of Object.entries(dragged))
      expect(demo.values[key]).toBeCloseTo(range.from, 6);
    expect(demo.ui).toMatchObject({
      tab: "zoom",
      webcamAspect: "Wide",
      webcamShape: "Rounded",
      cursorSize: "M",
    });
    expect(
      demo.updates.filter((ui, i, all) => i === 0 || ui.tab !== all[i - 1].tab).map((ui) => ui.tab),
    ).toEqual([
      "zoom",
      "background",
      "webcam",
      "cursor",
      "audio",
      "zoom",
      "background",
      "webcam",
      "cursor",
      "audio",
      "zoom",
    ]);
  });
});

test("offscreen and hidden pauses resume without accumulating wall time or duplicate frames", () => {
  withDemo(false, (demo) => {
    expect(demo.frames.size).toBe(0);
    demo.visible(true);
    demo.advance(3.5);
    const value = demo.values.zoomScale;
    demo.hidden(true);
    demo.advance(20);
    expect(demo.frames.size).toBe(0);
    expect(demo.values.zoomScale).toBe(value);
    demo.visible(false);
    demo.hidden(false);
    expect(demo.frames.size).toBe(0);
    demo.visible(true);
    demo.visible(true);
    expect(demo.frames.size).toBe(1);
    demo.frame();
    expect(demo.values.zoomScale).toBeGreaterThan(value);
    demo.frame(10000);
    expect(demo.values.zoomScale).toBeLessThan(dragged.zoomScale.to);
  });
});

test("initial reduced motion draws a still, observes preference changes, and cleans up", () => {
  withDemo(true, (demo) => {
    demo.visible(true);
    expect(demo.element("time").textContent).toBe("0:00.90");
    expect(demo.frames.size).toBe(0);
    expect(demo.updates).toHaveLength(0);
    demo.reduce(false);
    demo.advance(1);
    expect(demo.ui.selectedZoom).toBe("z1");
    demo.reduce(true);
    const time = demo.element("time").textContent;
    demo.advance(2);
    expect(demo.frames.size).toBe(0);
    expect(demo.element("time").textContent).toBe(time);
    demo.cleanup();
    expect(demo.disconnected).toBe(true);
    expect(demo.preference.size).toBe(0);
    expect(demo.visibility.size).toBe(0);
    expect(demo.timers.size).toBe(0);
    expect(demo.element("pointer").hasAttribute("data-pressed")).toBe(false);
  });
});

test("enabling reduced motion during a drag freezes and resumes the same edit", () => {
  withDemo(false, (demo) => {
    demo.visible(true);
    demo.advance(3.5);
    demo.reduce(true);
    const value = demo.values.zoomScale;
    demo.advance(5);
    expect(demo.frames.size).toBe(0);
    expect(demo.values.zoomScale).toBe(value);
    demo.reduce(false);
    demo.advance(1);
    expect(demo.values.zoomScale).toBe(dragged.zoomScale.to);
    demo.cleanup();
    expect(demo.frames.size).toBe(0);
    expect(demo.preference.size).toBe(0);
  });
});

test("cleanup cancels a pending click timer and the active animation frame", () => {
  withDemo(false, (demo) => {
    demo.visible(true);
    demo.advance(1.19);
    demo.frame(20, false);
    expect(demo.timers.size).toBe(1);
    expect(demo.element("pointer").hasAttribute("data-pressed")).toBe(true);
    demo.cleanup();
    expect(demo.timers.size).toBe(0);
    expect(demo.frames.size).toBe(0);
    expect(demo.visibility.size).toBe(0);
    expect(demo.preference.size).toBe(0);
    expect(demo.element("pointer").hasAttribute("data-pressed")).toBe(false);
  });
});

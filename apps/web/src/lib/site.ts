/** Facts the marketing site repeats in several places. Keep them in step with apps/macos. */
export const site = {
  /** The product (the Mac app). */
  name: "My Screen Cam",
  /** The website's own name, matching its domain. */
  brand: "MyScreen.cam",
  url: "https://myscreen.cam",
  description:
    "A native macOS screen recorder that turns raw recordings into finished videos: zooms that follow your cursor, painted backgrounds, webcam framing and hardware-accelerated export.",
  /** Stable DMG asset uploaded by apps/macos/scripts/release/release.sh. */
  downloadUrl:
    "https://github.com/arkaydeus/myscreencam/releases/latest/download/MyScreenCam.dmg",
  releasesUrl: "https://github.com/arkaydeus/myscreencam/releases/latest",
  requirements: "macOS 15 Sequoia or later, Apple silicon",
} as const;

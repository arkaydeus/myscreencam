/** Facts the marketing site repeats in several places. Keep them in step with apps/macos. */
export const site = {
  name: "MyScreenArt",
  url: "https://myscreenart.com",
  description:
    "A native macOS screen recorder that turns raw recordings into finished videos: zooms that follow your cursor, painted backgrounds, webcam framing and hardware-accelerated export.",
  /** Stable DMG asset uploaded by apps/macos/scripts/release/release.sh. */
  downloadUrl:
    "https://github.com/arkaydeustech/myscreenart-releases/releases/latest/download/MyScreenArt.dmg",
  releasesUrl: "https://github.com/arkaydeustech/myscreenart-releases/releases/latest",
  requirements: "macOS 15 Sequoia or later, Apple silicon",
} as const;

import { Command, FolderLock, Link2, MenuSquare, RefreshCw, ScanEye } from "lucide-react";

const details = [
  {
    icon: MenuSquare,
    title: "Always one click away",
    body: "Start and stop from the menu bar, or from the floating bar while you record. You can also hide the Dock icon while the app is idle.",
  },
  {
    icon: Command,
    title: "Shortcuts from any app",
    body: "Open the recorder with ⌥⌘↩ and finish with ⌥⇧⌘R.",
  },
  {
    icon: ScanEye,
    title: "Previews in Finder",
    body: "Recordings show thumbnails in Finder and Quick Look. Double-click one to open it in the editor.",
  },
  {
    icon: FolderLock,
    title: "Stays on your Mac",
    body: "No account and no uploads. Recordings are saved to your Movies folder.",
  },
  {
    icon: Link2,
    title: "Works with Shortcuts",
    body: "Start, finish and open recordings from the Shortcuts app, or from scripts with myscreenart:// links.",
  },
  {
    icon: RefreshCw,
    title: "Updates itself",
    body: "Signed and notarised by Apple. New versions download in the background and install when you’re ready.",
  },
];

export function MacDetails() {
  return (
    <section className="border-t border-rule">
      <div className="mx-auto w-full max-w-7xl px-5 py-20 sm:px-8 sm:py-28">
        <h2 className="max-w-[18ch] font-display text-4xl leading-none font-extrabold tracking-[-0.03em] sm:text-5xl">
          Made for the Mac, not ported to it.
        </h2>
        <ul className="mt-14 grid gap-x-10 gap-y-10 sm:grid-cols-2 lg:grid-cols-3">
          {details.map((d) => (
            <li key={d.title}>
              <d.icon aria-hidden className="size-6 text-ultramarine" />
              <h3 className="mt-4 font-semibold">{d.title}</h3>
              <p className="mt-1.5 max-w-[42ch] leading-relaxed text-muted-foreground">{d.body}</p>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}

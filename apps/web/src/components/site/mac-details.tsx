import { Command, FolderLock, Link2, RefreshCw, ScanEye, SquareMenu } from "lucide-react";

import { sectionTitle } from "@/components/site/brand";

const details = [
  {
    icon: SquareMenu,
    title: "Always one click away.",
    body: "Start and stop from the menu bar, or from the floating bar while you record. You can also hide the Dock icon while the app is idle.",
  },
  {
    icon: Command,
    title: "Shortcuts from any app.",
    body: "Open the recorder with ⌥⌘↩ and finish with ⌥⇧⌘R.",
  },
  {
    icon: ScanEye,
    title: "Previews in Finder.",
    body: "Recordings show thumbnails in Finder and Quick Look. Double-click one to open it in the editor.",
  },
  {
    icon: FolderLock,
    title: "Stays on your Mac.",
    body: "No account and no uploads. Recordings are saved to your Movies folder.",
  },
  {
    icon: Link2,
    title: "Works with Shortcuts.",
    body: "Start, finish and open recordings from the Shortcuts app, or from scripts with myscreenart:// links.",
  },
  {
    icon: RefreshCw,
    title: "Updates itself.",
    body: "Signed and notarised by Apple. New versions download in the background and install when you’re ready.",
  },
];

export function MacDetails() {
  return (
    <section className="bg-paper py-18 sm:py-30">
      <div className="page-width">
        <h2 className={sectionTitle}>
          Made for the Mac.
          <br />
          <span className="text-muted-foreground">Not ported to it.</span>
        </h2>
        <ul className="mt-8 grid gap-3 sm:mt-14 sm:grid-cols-2 sm:gap-5 lg:grid-cols-3">
          {details.map((d) => (
            <li
              key={d.title}
              className="flex gap-4 rounded-3xl bg-white p-6 sm:block sm:rounded-[28px] sm:p-9"
            >
              <d.icon
                aria-hidden
                className="size-6.5 shrink-0 text-primary sm:size-8"
                strokeWidth={1.75}
              />
              <div>
                <h3 className="text-[17px] font-semibold sm:mt-5 sm:text-[21px]">{d.title}</h3>
                <p className="mt-1 text-[15px] leading-[1.47] text-muted-foreground sm:mt-2 sm:text-[17px]">
                  {d.body}
                </p>
              </div>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}

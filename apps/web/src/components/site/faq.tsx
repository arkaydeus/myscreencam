import { Plus } from "lucide-react";

import { sectionTitle } from "@/components/site/brand";
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from "@/components/ui/accordion";
import { site } from "@/lib/site";

const questions = [
  {
    q: "What do I need to run it?",
    a: `${site.requirements}. It’s a single app of its own, with nothing else to install.`,
  },
  {
    q: "Which permissions does it ask for?",
    a: "Screen & System Audio Recording, so it can capture your screen and sound. Input Monitoring, so it can record where you click for zooms and click rings. Camera and Microphone only if you record them. macOS asks the first time each one is needed.",
  },
  {
    q: "Can I record system audio without extra software?",
    a: "Yes. MyScreenArt uses macOS’s built-in audio capture, so there’s no virtual audio device or driver to set up. System audio and your microphone are kept on separate tracks.",
  },
  {
    q: "Where are my recordings kept?",
    a: "In the MyScreenArt folder inside your Movies folder. Each recording is a single file you can move, back up or share. Nothing is uploaded anywhere.",
  },
  {
    q: "Can I change an edit after exporting?",
    a: "Yes. Edits are stored alongside the original footage and saved as you go, so you can reopen a recording at any time, change it, and export again.",
  },
  {
    q: "How do updates work?",
    a: "The app checks for new versions in the background. Updates are signed, and they install when you choose, never in the middle of a recording or an export.",
  },
];

export function Faq() {
  return (
    <section id="faq" className="scroll-mt-13 py-18 sm:py-30">
      <div className="page-width-narrow">
        <h2 className={sectionTitle}>Questions? Answers.</h2>
        <Accordion defaultValue={[questions[0].q]} className="mt-7 border-b border-rule sm:mt-12">
          {questions.map((item) => (
            <AccordionItem key={item.q} value={item.q} className="border-t border-rule">
              <AccordionTrigger className="min-h-16 items-center gap-6 rounded-none py-3.5 text-[17px] font-semibold hover:no-underline **:data-[slot=accordion-trigger-icon]:hidden sm:min-h-19 sm:text-[21px]">
                {item.q}
                <Plus
                  aria-hidden
                  strokeWidth={1.75}
                  className="ml-auto size-5 shrink-0 transition-transform duration-300 group-aria-expanded/accordion-trigger:rotate-45 sm:size-[22px]"
                />
              </AccordionTrigger>
              <AccordionContent className="pb-5 text-[15px] leading-[1.47] text-muted-foreground sm:pb-7 sm:text-[17px]">
                <p className="max-w-[760px]">{item.a}</p>
              </AccordionContent>
            </AccordionItem>
          ))}
        </Accordion>
      </div>
    </section>
  );
}

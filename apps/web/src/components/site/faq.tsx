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
    <section id="faq" className="scroll-mt-8 border-t border-rule">
      <div className="mx-auto grid w-full max-w-7xl gap-10 px-5 py-20 sm:px-8 sm:py-28 lg:grid-cols-[minmax(0,26rem)_1fr]">
        <h2 className="font-display text-4xl leading-none font-extrabold tracking-[-0.03em] sm:text-5xl">
          Questions
        </h2>
        <Accordion className="border-t border-rule">
          {questions.map((item) => (
            <AccordionItem key={item.q} value={item.q} className="border-b border-rule">
              <AccordionTrigger className="py-5 text-base font-semibold hover:no-underline sm:text-lg">
                {item.q}
              </AccordionTrigger>
              <AccordionContent className="pb-5 text-base leading-relaxed text-muted-foreground">
                <p className="max-w-[62ch]">{item.a}</p>
              </AccordionContent>
            </AccordionItem>
          ))}
        </Accordion>
      </div>
    </section>
  );
}

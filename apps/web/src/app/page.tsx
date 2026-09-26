import { Closing, SiteFooter } from "@/components/site/closing";
import { Faq } from "@/components/site/faq";
import { Hero } from "@/components/site/hero";
import { Highlights } from "@/components/site/highlights";
import { HowItWorks } from "@/components/site/how-it-works";
import { MacDetails } from "@/components/site/mac-details";
import { Performance } from "@/components/site/performance";
import { SiteHeader } from "@/components/site/site-header";

export default function Home() {
  return (
    <div id="top">
      <SiteHeader />
      <main>
        <Hero />
        <Highlights />
        <HowItWorks />
        <Performance />
        <MacDetails />
        <Faq />
        <Closing />
      </main>
      <SiteFooter />
    </div>
  );
}

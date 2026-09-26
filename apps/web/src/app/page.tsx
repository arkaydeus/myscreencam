import { Closing, SiteFooter } from "@/components/site/closing";
import { Faq } from "@/components/site/faq";
import { Features } from "@/components/site/features";
import { Hero } from "@/components/site/hero";
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
        <HowItWorks />
        <Features />
        <Performance />
        <MacDetails />
        <Faq />
        <Closing />
      </main>
      <SiteFooter />
    </div>
  );
}

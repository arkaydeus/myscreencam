import type { Metadata } from "next";
import Link from "next/link";
import { Stripe } from "stripe";

import { CopyLicence } from "./copy-licence";
import { licenceForSession } from "@/lib/licence";

export const metadata: Metadata = {
  title: "Thanks for buying My Screen Cam",
  robots: { index: false, follow: false },
};

export default async function Thanks({
  searchParams,
}: {
  searchParams: Promise<{ session_id?: string }>;
}) {
  const { session_id: sessionID } = await searchParams;
  let key: string | undefined;
  let pending = false;
  if (
    sessionID?.startsWith("cs_") &&
    process.env.STRIPE_SECRET_KEY &&
    process.env.LICENCE_SIGNING_KEY
  ) {
    try {
      const session = await new Stripe(process.env.STRIPE_SECRET_KEY).checkout.sessions.retrieve(
        sessionID,
      );
      if (session.payment_status === "paid") {
        key = licenceForSession(session, process.env.LICENCE_SIGNING_KEY);
      } else {
        pending = true;
      }
    } catch (error) {
      console.error("Could not retrieve Checkout session", { sessionID, error });
    }
  }
  return (
    <main className="page-width mx-auto max-w-2xl py-24 text-center">
      <h1 className="text-4xl font-semibold">
        {key
          ? "Thanks for buying My Screen Cam."
          : pending
            ? "Your payment is processing."
            : "We couldn't find that purchase."}
      </h1>
      {key ? (
        <>
          <p className="mt-5">
            Your licence key is below. We&apos;ll also send it to your checkout email.
          </p>
          <CopyLicence licence={key} />
          <p className="mt-5">Keep your key safe for future activation.</p>
        </>
      ) : (
        <p className="mt-5">
          {pending
            ? "We'll email your licence key once payment is confirmed."
            : "Check your confirmation link or contact support with your receipt."}
        </p>
      )}
      <Link className="mt-8 inline-block text-primary underline" href="/">
        Back to My Screen Cam
      </Link>
    </main>
  );
}

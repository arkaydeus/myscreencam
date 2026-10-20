import { Nunito } from "next/font/google";

/** The wordmark's face, for the product name in the header and hero. next/font self-hosts it, so the browser never calls Google. */
export const wordmark = Nunito({ weight: "800", subsets: ["latin"] });

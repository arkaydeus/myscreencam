const SHIPMAIL_MESSAGES_URL = "https://shipmail.to/api/v1/messages";

/**
 * The Shipmail key for this environment. NODE_ENV=production (including `next build` and `next start`, even locally)
 * selects `SHIPMAIL_API_KEY`; `next dev` and tests select `SHIPMAIL_API_KEY_TEST`. There is no fallback between them.
 * For previews or local production runs that should simulate sends, set `SHIPMAIL_API_KEY` to a test key.
 */
export function shipmailApiKey(
  env: Record<string, string | undefined> = process.env,
): string | undefined {
  return (
    (env.NODE_ENV === "production" ? env.SHIPMAIL_API_KEY : env.SHIPMAIL_API_KEY_TEST) || undefined
  );
}

const ADDRESS = /^[^\s<>@,;]+@[^\s<>@,;]+\.[^\s<>@,;]+$/;

/** A single sender: `info@myscreen.cam` or `My Screen Cam <info@myscreen.cam>`. */
export function isSenderAddress(value: string | undefined): boolean {
  if (!value) return false;
  const named = /^[^<>,;@]+<([^<>\s]+)>$/.exec(value.trim());
  return ADDRESS.test(named ? named[1] : value.trim());
}

/**
 * Emails a licence key from a Shipmail mailbox (`info@myscreen.cam`). Replies go straight to that mailbox, and
 * every licence email also lands in its Sent folder.
 *
 * `from` is the mailbox address, optionally with a display name (`My Screen Cam <info@myscreen.cam>`), which applies
 * to this send only. The idempotency key makes a retry return the first message instead of sending a second email.
 */
export async function sendLicenceEmail(options: {
  apiKey: string;
  from: string;
  to: string;
  licence: string;
  idempotencyKey: string;
}): Promise<void> {
  const response = await fetch(SHIPMAIL_MESSAGES_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${options.apiKey}`,
      "Content-Type": "application/json",
      "Idempotency-Key": options.idempotencyKey,
    },
    body: JSON.stringify({
      from: options.from,
      to: [options.to],
      subject: "Your My Screen Cam licence",
      text: `Thanks for buying My Screen Cam. Your licence key is:\n\n${options.licence}\n\nKeep this email so you can activate again later.`,
    }),
  });
  if (!response.ok) throw new Error(`Email service returned ${response.status}`);
}

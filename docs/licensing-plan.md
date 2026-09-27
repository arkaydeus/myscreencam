# Paid licences: plan

Status: **draft for review (2026-09-27)**. The open decisions are in §8.

My Screen Cam is sold directly for **£9.99 / $9.99**, outside the Mac App Store. Payment goes through **Stripe Managed
Payments**, so Stripe is the merchant of record and handles VAT and sales tax. Buyers get a **signed licence key**
that the app checks offline. The free download is the full app, but an **unlicensed copy watermarks its exports**.

Settled before this plan:
- Not the Mac App Store: it would need the App Sandbox, which breaks the speech XPC service's file access and rules
  out Sparkle.
- Stripe Managed Payments rather than plain Stripe (we'd file VAT/sales tax ourselves) or Lemon Squeezy (being folded
  into Managed Payments; its keys only work while its API does).
- Licence keys we sign ourselves, so they survive a change of payment provider.
- Unlicensed = watermark on exports. Nothing else is locked.

## 1. What the user gets

1. **Download** from the website, as now. Everything works. Exported videos and GIFs carry a small
   "MyScreen.cam" badge (§4).
2. **Buy** from the site's Buy button (a hosted Stripe Checkout page) or from the app (**My Screen Cam › Buy My Screen Cam…**,
   and the banner in the export sheet). Stripe's checkout shows the local price including tax.
3. **After paying** they land on `myscreen.cam/thanks`. It shows the licence key, a Copy button and an
   **Activate in My Screen Cam** button (`myscreencam://activate?key=…`). The same key arrives by email.
4. **Activating**: the button, or pasting the key into **Settings › Licence**. The pane then shows
   *Licensed to jane@example.com*. The watermark disappears from the preview and from every export started after
   that. No account and no network connection are needed, now or later.
5. **Lost key**: `myscreen.cam/licence` takes an email address and re-sends the key(s) bought with it.

## 2. Licence keys

**Format:** `MSC1.<payload>.<signature>`, both parts base64url.
- **Payload**: compact UTF-8 JSON, for example
  `{"v":1,"id":"lic_4k2m9q7x1c8b3n5p","email":"jane@example.com","product":"myscreencam","issued":"2026-09-27"}`.
  - `id` is `lic_` followed by 16 base32 characters of SHA-256(Checkout Session ID).
  - `product` lets a future paid major version use a different value without breaking today's keys.
- **Signature**: Ed25519 over the **exact payload bytes**. The app never re-serialises the JSON, so there's no
  canonicalisation to get wrong.
- A key is about 200 characters: meant to be clicked or pasted, not typed.

**Signing** happens only on the server (Node `crypto`, Ed25519). Node's signatures are deterministic, and the
payload is derived only from the Checkout Session. So re-issuing a key for a lost-key request produces the
identical key, and **no database is needed**: Stripe is the only record.

**Verifying** happens only in the app, with CryptoKit (`Curve25519.Signing.PublicKey.isValidSignature`) against a
public key built into the app, the same way the Sparkle key is handled:
- The build setting `MSC_LICENCE_PUBLIC_KEYS` goes into Info.plist.
- It's a list, so the signing key can be rotated in a later release.
- Verification order: parse → signature → `product == "myscreencam"` → id not in the revoked list.

**Keypairs**:

| | Signs | App that accepts it | Stripe mode |
|---|---|---|---|
| **Production** | Private key in the Production environment variables, backed up in a password manager | Release | Live |
| **Development** | Private key committed in the repo; it only unlocks Debug builds | Debug | Test |

Losing the production private key means no new keys that shipped apps accept, until an update adds a new
public key. Back it up.

**Revocation** (refunds, chargebacks, keys posted publicly): a short `revoked-licences.json` in the app's
resources, updated in a release. Stripe handles the refund itself.

**Accepted limits**. At £9.99, fighting harder isn't worth it:
- A key can be shared. The email shown in Settings is the only deterrent.
- The raw `screen.mov` inside a `.mscam` is unwatermarked. The editing is what people pay for.
- A patched binary gets around any client-side check.

## 3. How it fits the app

| Piece | Where | Notes |
|---|---|---|
| Key parsing and verification | `MyScreenCamCore/Licence.swift` | Pure: `LicenceKey.parse(_:)` and `verify(publicKeys:revoked:) throws -> Licence`. Errors: `malformed`, `badSignature`, `wrongProduct`, `revoked`. Tolerates whitespace and newlines in pasted keys. |
| Licence state | `App/Sources/Licence/LicenceStore.swift` (a new area) | `@Observable`, owned by `AppModel`. Keeps the key string in `UserDefaults` (it's signed, so editing it gains nothing) and re-verifies it at launch. Cross-area API: `LicenceStore.isLicensed`, `licence`, `activate(key:)`, `remove()`. |
| Settings › Licence | `Licence/LicenceSettingsView.swift`, a new tab in `Shell/SettingsView.swift` | Unlicensed: a key field, **Activate** and **Buy My Screen Cam…**. Licensed: *Licensed to …*, the licence ID, and **Remove Licence**. |
| URL scheme | `AppURLCommand.activateLicence(key:)` for `myscreencam://activate?key=…` | Goes through `ShellActions`, like the other URL commands. Activates the key and opens Settings › Licence to confirm it. A bad key shows the reason there. |
| Menu | App menu: **Buy My Screen Cam…** (hidden once licensed) and **Licence…** | Both go through `ShellActions`. |
| Watermark flag | `RenderOptions.watermark: Bool` (default `false`) → `CompositionBuilder` → `RenderSnapshot` | `EditorWindow` and `ExportPipeline.prepare` pass `!licence.isLicensed`. Activating while an editor is open calls `ProjectRenderer.update(options:)`, so the preview updates without a reload. |
| Watermark drawing | `RenderKit/Compositor/WatermarkRenderer.swift`, `Math/WatermarkLayout.swift` | Step 8 of `FrameRenderer.compose`, in canvas space after subtitles, before the final resize. The badge is rasterised once per canvas size (Core Text plus the app icon) and cached in `ProjectResources`, like subtitle rasters, so each frame costs one GPU composite. `WatermarkLayout` is the pure geometry, tested per canvas size. |
| Export sheet | `Export/ExportSheet.swift` | Unlicensed: a one-line banner, *Exports include a small My Screen Cam watermark*, with **Buy…** and **Enter Licence…**. |
| Exports | `ExportCenter` | A queued export captures `watermark` when it's queued. MOV, MP4 and GIF all go through the same compositor, so all three are covered. `.srt` files aren't touched. `msc-tool export` (dev only) never watermarks. |

`apps/macos/CLAUDE.md` gets the new area and its skeleton API. `docs/release.md` gets the licence keys.

## 4. The watermark

Default look (Q1):
- **Content**: the app icon plus "MyScreen.cam", in white semibold with a soft shadow, so it reads on
  light and dark footage.
- **Size**: height 3.5% of the canvas height.
- **Position**: top-right, with a margin of 2% of the canvas height.
  - Top-right avoids the defaults: the webcam sits bottom-right (origin 0.78, 0.72) and subtitles bottom-centre.
  - It's fixed; the user can't move it.
- **Opacity**: 85%.

Because it's drawn in canvas space, it never zooms or follows the cursor. It sits over the background padding
when a background is on. GIFs get the same badge, scaled with the canvas.

## 5. The website (`apps/web`)

The landing page stays static. New dynamic pieces (Node runtime):

| Piece | Where | Notes |
|---|---|---|
| Buy button | A form posting to `src/app/api/checkout/route.ts` (**built**), which creates a Managed Payments Checkout Session and redirects to it; `site.ts` gains the price; hero, closing section and product bar | Content rule: the price on the site is the real Stripe price. Setup: `STRIPE_INTEGRATION_TODO.md`. |
| Webhook | `src/app/api/stripe/webhook/route.ts` | Verifies the Stripe signature on the raw body. Handles `checkout.session.completed` when `payment_status == "paid"`, and `checkout.session.async_payment_succeeded`. Signs the key and emails it (Resend, using the event ID as the idempotency key). Stripe retries are harmless because the key is deterministic. |
| Thanks page | `src/app/thanks/page.tsx` | Checkout's `success_url` is `/thanks?session_id={CHECKOUT_SESSION_ID}`. Server-side it retrieves the session. Paid: shows the key, Copy, **Activate in My Screen Cam** and a download link. Otherwise: "Payment still processing — we'll email your key". `noindex`. |
| Lost-key page | `src/app/licence/page.tsx` + a server action | Looks up paid Checkout Sessions for the email address and emails the keys. It always answers "If there's a purchase for that address, we've emailed it", so it doesn't reveal who has bought. Rate-limited per IP. |
| Signing | `src/lib/licence.ts` | Encodes and signs. The one place the private key is used. |
| FAQ and copy | `faq.tsx`, `closing.tsx` | "What does the free download do?" (everything; exports carry a watermark until you buy). Price and licence terms. |

**Environment variables**:
- `STRIPE_SECRET_KEY`: a *restricted* key with write access to Checkout Sessions only (create and read).
- `STRIPE_WEBHOOK_SECRET`
- `LICENCE_SIGNING_KEY`: Ed25519 PKCS#8, base64.
- `RESEND_API_KEY`
- `LICENCE_EMAIL_FROM`

Preview deployments use the Stripe test mode keys and the development keypair.

New dependencies: `stripe` and `resend` (npm). Nothing new in the app.

## 6. Phases

0. **Accounts (you)**, all in Stripe test mode first.
   - Turn on Managed Payments and confirm a UK business is eligible.
   - Create the product "My Screen Cam" with Managed Payments' digital-software tax code, a **£9.99 GBP** price
     (tax-inclusive) and a **$9.99 USD** price.
   - Put the Price ID in the checkout route and a test secret key in `apps/web/.env.local` (`STRIPE_INTEGRATION_TODO.md`).
   - Resend: an account and a verified sending domain on `myscreen.cam`.
   - Hosting for the site's server routes (Q4).
1. **Licence format.**
   - A keypair script (`bun apps/web/scripts/licence-keygen.ts`) and the development keypair.
   - `src/lib/licence.ts` and `MyScreenCamCore/Licence.swift`.
   - One shared test-vector file that both test suites read, so the TypeScript signer and the Swift verifier can't
     drift apart.
2. **App licence.**
   - `LicenceStore`, Settings › Licence, the URL command, the menu items and the revoked list.
   - `mise run licence:dev` prints a development key and activation link for Debug builds.
3. **Watermark.**
   - Renderer, layout, preview, export and the export-sheet banner.
   - Measure an export with `scripts/perf/sample.py` before and after, and record it in `perf-baseline.md` (it
     should be noise).
4. **Website.** Webhook, thanks page, lost-key page, Buy button, FAQ and price copy.
5. **End to end**, then go live.
   - In test mode: buy with a Stripe test card (`stripe listen --forward-to` locally, then a preview
     deployment), get the email, click Activate in a Debug build, and check that the watermark disappears.
   - Then switch to live keys and the production keypair, cut a release, and make one real purchase.

## 7. Tests

- **Swift** (`MyScreenCamCoreTests`, Swift Testing):
  - Verification against the shared vectors: valid key; tampered payload; tampered signature; wrong public key;
    second key in the list; wrong product; revoked; garbage, empty and truncated input; pasted keys with
    newlines.
  - `AppURLCommand` parsing of `activate`.
- **Swift** (`RenderKitTests`):
  - `WatermarkLayout` for 16:9, 9:16, 1:1 and GIF-sized canvases: stays inside the canvas, scales with height.
  - `FrameRenderer` output differs only in the badge rect when the watermark is on.
- **Web** (`bun test`):
  - The signer reproduces the shared vectors.
  - The webhook rejects bad signatures, ignores unpaid sessions and emails exactly one key per paid session.
  - The lost-key action gives the same response for known and unknown addresses.

## 8. Decisions (defaults in bold; I'll use them unless you say otherwise)

1. **Watermark look**: **small badge, icon plus "MyScreen.cam", top-right, 85% opacity**. The
   alternatives are bottom-left, or a large translucent diagonal mark (harder to crop out, but it spoils the
   trial).
2. **Watermark in the preview too?** **Yes**. Preview and export come from the same renderer (what you see is what
   you export), and it's a steady reminder. The alternative is a clean preview and only the export-sheet banner.
3. **What a licence covers**: **every 1.x and later version of My Screen Cam**. The `product` field leaves room to
   charge for a future major version if you ever want to.
4. **Hosting for the webhook and pages**: **Vercel**, since the site is Next.js. Where is myscreen.cam hosted
   today?
5. **Email**: **Resend**. Postmark is the main alternative.
6. **Revocation**: **a bundled revoked list, updated in releases**, or no revocation at all.

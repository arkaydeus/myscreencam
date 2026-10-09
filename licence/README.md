# Licence keys: shared fixtures

The website signs licence keys (`apps/web/src/lib/licence.ts`) and the app verifies them
(`apps/macos/Packages/MyScreenCamKit/Sources/MyScreenCamCore/Licence.swift`). The format and the plan are in
`docs/licensing-plan.md`. Both sides are tested against the file here, so they can't drift apart.

**No private key is ever committed.** Not for production, and not a "development only" one. Only public material
lives in git, and `apps/web/tests/no-private-keys.test.mjs` fails if a private key turns up in any tracked or
unignored file.

| File | What it is |
|---|---|
| `test-vectors.json` | Generated. Licence keys signed with a throwaway key, the public keys that go with them, and the verdict the app must give for each (valid, malformed, bad signature, wrong product, revoked). Signatures and public keys only. |

## How the pieces get their keys

| Who | Signing key | Public key |
|---|---|---|
| **Website tests** | A throwaway pair made at test time | Same |
| **Swift tests** | None. They only verify. | `publicKeys.signer` in `test-vectors.json` |
| **Local website and Debug app** | `LICENCE_SIGNING_KEY` in the git-ignored root `.env`. Make one with `cd apps/web && bun run licence:dev-key`. It's never printed, and each developer has their own. | Derived from that key (the phase 2 `mise run licence:dev` task). Not committed. |
| **Production** | The host's `LICENCE_SIGNING_KEY`, backed up in a password manager | The app's `MSC_LICENCE_PUBLIC_KEYS` build setting for Release |

## Commands (from `apps/web`)

- `bun run licence:vectors` regenerates `test-vectors.json` with a fresh throwaway key whose private half is
  discarded. Only needed when the licence format changes.
- `bun run licence:dev-key` writes a new `LICENCE_SIGNING_KEY` into the root `.env` and prints the matching public
  key. Run it again to rotate.
- `bun run licence:keygen` prints a keypair and writes nothing. Use it for the production pair.

## Rules

- **A Release build must never trust a development public key.** Phase 2 adds the `MSC_LICENCE_PUBLIC_KEYS` build
  setting, and it must come with a check that fails the Release build or test run if that setting contains the public
  key of any development signing key.
- Never paste a signing key into a chat, a commit message, a log or a ticket.

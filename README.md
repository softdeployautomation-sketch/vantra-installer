# Vantra Installer

## What this repo is for

Vantra is a customer-facing portal built on top of a self-hosted TacticalRMM instance. When a customer adds a device, Vantra generates a Windows installer (an `.exe`, produced by TacticalRMM's own build service) plus an install command the customer runs. Today customers download that `.exe` directly, but antivirus software sometimes flags it as suspicious — a common problem with generic/community-signed RMM agent installers.

This repo is for converting that installer + install command into a single, properly packaged **MSI** that installs unattended (no manual command line for the customer) and addresses the antivirus/signing issue. This is security- and packaging-focused work — not related to the Vantra web app's own codebase, which lives in a separate repo.

## What you're wrapping, exactly

The current install flow a customer's browser triggers looks like this (real example, captured during testing):

```
tacticalagent-v2.11.0-windows-amd64.exe /VERYSILENT /SUPPRESSMSGBOXES &&
ping 127.0.0.1 -n 7 &&
"C:\Program Files\TacticalAgent\tacticalrmm.exe" -m install --api https://api.instaweb.top ^
  --client-id <id> --site-id <id> --agent-type <server|workstation> --auth <token>
```

Breaking that down:

- **`tacticalagent-vX.X.X-windows-amd64.exe`** — the actual TacticalRMM agent binary. This file is generated per-download by TacticalRMM's own hosted build/merge service (we don't host or build this ourselves) and already bakes in a Windows installer wrapper (`/VERYSILENT /SUPPRESSMSGBOXES` are Inno Setup flags).
- **`tacticalrmm.exe -m install ...`** — after the base agent is unpacked, this second step actually *registers* the agent with our TacticalRMM server (client, site, agent type) and authenticates using a token.
- **`--auth <token>`** — this is a **short-lived credential**, currently valid for 72 hours, scoped to one specific client/site. **Do not design the MSI to hardcode a long-lived version of this token.** If your MSI needs to fetch a token at install time rather than embedding a static one baked in ahead of time, that's a more robust direction — your call as the security lead here, not prescribed by this repo.

See [`docs/agent-install-reference.md`](docs/agent-install-reference.md) for more background (the TacticalRMM API mechanics behind this, and a known related blocker for non-Windows platforms).

## "Unattended download" — what that means today, and an open question for you

Right now, Vantra generates a per-device download link (`https://api.instaweb.top/clients/{some-id}/deploy/`) and the customer clicks it, downloads the `.exe`, and runs it — no manual command-line entry required already. The problem isn't the *download* step, it's that antivirus software sometimes blocks/flags the file itself.

**Open question for you to confirm with the product owner before building**: does your MSI approach still expect Vantra to hand out a similar per-deployment download link (same idea, just serving an `.msi` instead of an `.exe`), or does your design need something different from Vantra's side (a different API call, a different hosting location, etc.)? Please raise this rather than assuming — it affects what, if anything, needs to change on the Vantra web app side to support your work.

## Branch workflow

- **`main` is protected.** No direct pushes — every change goes through a pull request and gets reviewed before merging.
- **Push all your work to the `installer-dev` branch.** You have write access to push there freely.
- **Open a PR from `installer-dev` → `main`** whenever a chunk of work is ready for review. Small, focused PRs are easier to review than one giant one — feel free to open PRs incrementally as you make progress, rather than waiting until everything is "done."

## Security — please read

- **Never commit signing certificates, private keys, `.env` files, or any TacticalRMM/Vantra API credentials** to any branch, even "temporarily" or "to test something quickly." Once something is committed, it's in git history even if you delete it in a later commit.
- Check that `.gitignore` actually covers your tooling's real output/cache paths — the defaults here are a starting guess (common cert extensions, `build/`/`dist/`/`.msi` output folders), not a guarantee your specific toolchain won't leave something sensitive somewhere unexpected.
- **If you ever accidentally commit a secret, say so immediately** rather than just deleting it in a follow-up commit — it needs to be rotated (a new key/cert issued), not just hidden from view, since it's still recoverable from git history.

## The Vantra web app repo — you can read it, but not push to it

You've also been given **read-only** access to [`Mikeolab/vantra`](https://github.com/Mikeolab/vantra) — the actual customer portal codebase this installer work supports. You can clone it and look around for deeper context (e.g. the real `lib/trmm.ts` API integration code) if `docs/agent-install-reference.md` in this repo isn't enough, but you don't have push access there and shouldn't need it. Any changes needed on the web app's side (to support whatever your MSI/installer design ends up requiring) are handled by the product owner and Claude, not by you directly — if you find you need something to change there, raise it as a question rather than opening a PR against it.

## Questions

For anything about Vantra's product direction, business requirements, or what a "correct" unattended-install experience should feel like from the customer's side — ask the product owner directly. For anything about this repo's structure or your PRs, they'll be reviewed here before merging.

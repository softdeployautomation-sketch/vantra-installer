# Agent Install Reference

Background detail on how Vantra's current Windows agent installer flow actually works, for context on what you're wrapping into an MSI. All of this was confirmed by testing directly against the live TacticalRMM API and reading its (open source) source code — not guesswork.

## The moving parts

1. **TacticalRMM server** — our self-hosted instance of the open-source RMM platform (github.com/amidaware/tacticalrmm). It has its own REST API, which Vantra's web app calls server-to-server.
2. **A "Deployment"** — a TacticalRMM object representing one pending installation: which client/site it belongs to, what OS/architecture, and a time-limited auth token. Vantra creates one of these each time a customer clicks "Add Device."
3. **The download link** — `GET https://api.instaweb.top/clients/{deployment-uid}/deploy/`. This is a public (no authentication required) endpoint — the UUID in the URL is itself the access token, so it's safe to hand directly to a customer's browser. Hitting it returns the actual `.exe` file, generated fresh by TacticalRMM's own hosted build service (not something we run ourselves).
4. **The install command** — embedded inside the generated `.exe`'s behavior: it silently unpacks the base agent, then runs `tacticalrmm.exe -m install` with the client ID, site ID, agent type, and a short-lived auth token, which is what actually connects the newly-installed agent back to our server.

## Why the antivirus problem exists (context, not something to fix here)

The generated `.exe` is merged/signed via a community/generic code-signing certificate provided by TacticalRMM's maintainers (Amidaware), not a certificate specific to our own organization. Generic or shared signing certificates are common antivirus false-positive triggers, especially for RMM-category software (attacker-abused RMM tools are a known malware pattern, so AV vendors are aggressive about flagging anything in this category that isn't well-established). There's a separate, ongoing conversation with Amidaware about a paid/dedicated code-signing arrangement that would likely reduce this — that's being pursued independently of this repo's MSI-packaging work, though the two may end up complementary (a properly-signed MSI plus a properly-signed underlying agent would be the strongest combination).

## A related, currently-blocked feature (useful context, not your task unless asked)

TacticalRMM also supports Linux and macOS agents, but generating their installers via the API is **currently blocked server-side** unless a valid paid TacticalRMM code-signing token exists — same underlying signing-relationship dependency as the Windows AV issue above. If your MSI/signing work ends up resolving that broader signing relationship, it may unblock Mac/Linux installer support too — worth flagging back if you notice this, but not something you need to build.

## Token lifetime

The `--auth` token embedded in the install command is generated fresh per-Deployment and expires (currently configured for 72 hours after creation). It's scoped to one client/site combination — it cannot be reused to enroll a device against a different customer's account. Whatever your MSI design does with this token (bake it in at generation time vs. fetch a fresh one at install time), be aware it is not a long-lived credential and shouldn't be treated as one.

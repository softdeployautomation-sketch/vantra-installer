# Cline — Build the Vantra MSI Prototype (Phase 1)

Paste this entire file as your first message to Cline.

---

## What you're building

A 64-bit Windows MSI installer for Vantra — a customer portal built on TacticalRMM (an
open-source Remote Monitoring and Management platform). The MSI silently installs the
TacticalRMM Windows agent and registers it with the Vantra server, all without any visible
window or manual step from the customer.

Built using `wixl` on Linux (`msitools` package). No Windows machine required.

This is a **template-based prototype**. The source files (`Product.wxs` and
`orchestrator.ps1`) use `{{PLACEHOLDER}}` values that a build script fills in per
deployment. For this Phase 1 prototype, the build script accepts real values as arguments
so one working MSI can be produced and tested.

---

## The real install flow you are wrapping

The current TacticalRMM install flow (confirmed from live testing) is two sequential steps:

**Step 1 — Install the agent binary:**
Run `tacticalagent.exe` with Inno Setup's standard silent/no-dialog flags.
Wait for it to complete fully before proceeding.

**Step 2 — Register the agent with the Vantra server:**
After a short settle delay (see below), call `tacticalrmm.exe` with the `-m install`
subcommand, passing these named arguments:
- `--api` — the Vantra API base URL (default: `https://api.instaweb.top`)
- `--client-id` — value of `{{CLIENT_ID}}`
- `--site-id` — value of `{{SITE_ID}}`
- `--agent-type` — value of `{{AGENT_TYPE}}`
- `--auth` — value of `{{AUTH_TOKEN}}`

**Why the settle delay matters:**
The Inno Setup wrapper (Step 1) exits before the unpacked agent is fully ready. Without a
pause between Step 1 and Step 2, the registration command fails intermittently on slower
machines. Use 8 seconds minimum.

---

## Ground rules — read before writing a single line

1. **No terminal access.** Whenever a step requires a terminal command — generating GUIDs
   with `uuidgen`, running `wixl`, installing packages — stop and give the user the exact
   command to run and exactly what output you need back. The user's senior engineer (a
   separate Claude Code session with terminal access) runs all commands. Do not claim a
   command succeeded without seeing its real output.

2. **Never invent or substitute payload files.** If `payload/guide.pdf` or
   `payload/tacticalagent.exe` don't exist, stop and ask for them. Do not create
   placeholder versions.

3. **Before writing `src/orchestrator.ps1.template`**, confirm with the user:
   - Is `C:\Program Files\TacticalAgent\tacticalrmm.exe` the correct path on all
     supported Windows versions, or can it vary? If it can vary, the script must search
     for it rather than hard-coding the path.
   - Should the MSI silently succeed (exit 0 anyway) if registration fails — e.g. due to
     an expired token — so the agent files are at least installed? Or should it fail
     visibly? This is a product decision, not a technical one.

4. **GUIDs must be real.** Every `Id` in `Product.wxs` that takes a GUID must come from
   running `uuidgen` in a terminal. Stop and ask the senior engineer to run `uuidgen` for
   each one needed. List them all up front as a batch so it's one stop, not six.
   Do not invent or copy GUID-shaped strings.

5. **Never claim a build succeeded without showing real `wixl` output.** Report any errors
   exactly — do not paraphrase or summarize them.

---

## Files to write

### `src/orchestrator.ps1.template`

PowerShell script template. The build script substitutes `{{PLACEHOLDER}}` values before
this becomes the real `orchestrator.ps1` baked into the MSI.

Placeholders this file must contain:
- `{{CLIENT_ID}}` — TacticalRMM client ID
- `{{SITE_ID}}` — TacticalRMM site ID
- `{{AGENT_TYPE}}` — `workstation` or `server`
- `{{AUTH_TOKEN}}` — 72-hour registration token
- `{{API_URL}}` — Vantra API URL (default: `https://api.instaweb.top`)

The script must do the following steps in order:

**Step 1 — Create temp directory:**
[POWERSHELL: Create directory at path $env:TEMP\VantraSetup, force-create, suppress output]

**Step 2 — Copy agent EXE to temp:**
[POWERSHELL: Copy tacticalagent.exe from $PSScriptRoot into the temp directory, force overwrite]

**Step 3 — Run agent installer silently:**
[POWERSHELL: Launch tacticalagent.exe from temp directory using Inno Setup silent flags,
hidden window, no new window, wait for process to exit, capture the process object so the
exit code is readable afterward]

**Step 4 — Check installer exit code:**
[POWERSHELL: If exit code from Step 3 is not 0, remove the temp directory silently and
exit the script with exit code 1]

**Step 5 — Wait for agent to settle:**
[POWERSHELL: Sleep 8 seconds before proceeding to registration]

**Step 6 — Resolve tacticalrmm.exe path dynamically:**
[POWERSHELL: Try to find tacticalrmm.exe at the standard 64-bit Program Files path first,
then the 32-bit path as fallback. If not found at either location, remove temp directory
silently and exit with code 1. Store the resolved path in a variable for use in Step 7.]

**Step 7 — Run the registration command:**
[POWERSHELL: Launch the resolved tacticalrmm.exe with -m install and the five named
arguments (--api, --client-id, --site-id, --agent-type, --auth) using the {{PLACEHOLDER}}
values. Hidden window. Wait for it to complete. Capture exit code.]

**Step 8 — Clean up temp directory:**
[POWERSHELL: Remove the temp directory and all contents, silently, regardless of whether
Step 7 succeeded or failed. This must always run — put it in a finally block or after the
exit-code check.]

**Step 9 — Exit:**
[POWERSHELL: Exit with the exit code from Step 7]

No logging to permanent files. No visible windows at any stage. No Write-Host or
Write-Output that could surface text to the customer.

---

### `src/Product.wxs.template`

WiX source file template for `wixl`. All GUIDs are placeholders — the build script
substitutes real UUIDs before calling `wixl`.

GUID placeholders needed (one per line, for the uuidgen batch request):
- `{{GUID_PRODUCT}}` — Product Id
- `{{GUID_UPGRADE}}` — UpgradeCode
- `{{GUID_COMP_AGENT}}` — Component for tacticalagent.exe
- `{{GUID_COMP_GUIDE}}` — Component for guide.pdf
- `{{GUID_COMP_PS1}}` — Component for orchestrator.ps1
- `{{GUID_COMP_SHORTCUT}}` — Component for the Start Menu shortcut

Must define:

**Product and Package:**
- `Name`: `Vantra Agent`
- `Language`: `1033`
- `Version`: `1.0.0`
- `Manufacturer`: `{{MANUFACTURER}}`
- `InstallerVersion`: `405`
- `Compressed`: `yes`
- `InstallScope`: `perMachine`
- `Platform`: `x64`

Ask the user what `{{MANUFACTURER}}` should be — the legal organization name that will
appear in Windows' installed programs list. Must match the code-signing certificate
when Phase 2 signing is added.

**MajorUpgrade:**
Allow upgrades to newer versions. Block downgrades with an error message.

**MediaTemplate:**
Single embedded cab file (`EmbedCab="yes"`).

**Directory structure:**
Install to `ProgramFiles64Folder > {{MANUFACTURER}} > Vantra Agent` (the `INSTALLDIR`).
Also define a `ProgramMenuFolder > Vantra Agent` directory for the Start Menu shortcut.

**Components — one per installed file:**
- `tacticalagent.exe` in `INSTALLDIR` — KeyPath
- `guide.pdf` in `INSTALLDIR` — KeyPath
- `orchestrator.ps1` in `INSTALLDIR` — KeyPath
- Start Menu shortcut component in `SHORTCUTDIR`:
  - Shortcut named `Vantra Agent Guide` pointing to `guide.pdf` in `INSTALLDIR`
  - Include `RemoveFolder` and `RegistryValue` elements per WiX convention for clean
    uninstall of the Start Menu folder

**Feature** containing all four components.

**CustomAction:**
Runs `orchestrator.ps1` silently after files are installed.
[WIXL_CUSTOMACTION: Type 34 deferred custom action that calls powershell.exe from
SystemFolder with the orchestrator.ps1 path, using policy bypass and hidden/non-interactive
flags. Return="ignore" so that a registration failure does not roll back the install —
the agent files stay installed even if the first token has expired.]

**InstallExecuteSequence:**
Schedule the custom action after `InstallFiles`, conditioned on `NOT REMOVE` so it fires
only on install/repair, never on uninstall.

---

### `build/build.sh`

Bash script. Takes deployment parameters as named arguments and produces one `.msi` in
`dist/`. Usage:

```
./build/build.sh \
  --client-id <id> \
  --site-id <id> \
  --agent-type <workstation|server> \
  --auth-token <token> \
  --api-url https://api.instaweb.top \
  --manufacturer "Your Company Name"
```

The script must:

1. **Parse named arguments.** Use `while [[ $# -gt 0 ]]` / `case` pattern. Error and exit
   if any required argument is missing, naming the missing argument.

2. **Check `wixl` is installed.** If not found: print the apt install command and exit
   non-zero. Do not try to install it.

3. **Check payload files exist.** Both `payload/guide.pdf` and `payload/tacticalagent.exe`
   must be present. If either is missing, name it and exit non-zero.

4. **Generate 6 UUIDs.** Call `uuidgen` six times, one per GUID placeholder. Store each
   in a named variable. Print all six to stdout so they appear in the build log.

5. **Create a temp build directory.** Use `mktemp -d` or `/tmp/vantra-build-$$`. Copy
   `payload/` files and `src/` template files into it. Substitute all `{{PLACEHOLDER}}`
   values using `sed -e` chains. Write substituted files to temp dir — never modify
   `src/` templates in place.

6. **Print the exact `wixl` command, then run it:**
   `wixl -v -a x64 <tempdir>/Product.wxs -o dist/VantraAgent.msi`

7. **On non-zero exit:** print full wixl error output and exit non-zero.
   **On zero exit:** print the output MSI path and file size (`ls -lh dist/VantraAgent.msi`).

8. **Clean up the temp build directory.**

9. **Print a reminder:**
   ```
   Build complete.
   Next: sign the MSI (see msi-builder/signing/SIGNING.md), then scan with
   VirusTotal before distributing to customers.
   ```

Do not sign. Do not run the MSI. Signing is a separate manual step.

---

### `build/.gitkeep` and `dist/.gitkeep`

Empty files. Keep these directories tracked by git since build output is gitignored.

---

## Definition of done for Phase 1

- All source files written, matching the specs above.
- Every open question answered before those answers were used: MANUFACTURER name,
  registration failure behavior, tacticalrmm.exe path variation.
- GUIDs generated via real `uuidgen` calls — not invented.
- A real `wixl` build run by the senior engineer, showing actual terminal output.
- A `.msi` confirmed present in `dist/`, with file size printed.
- Signing and VirusTotal scan flagged as required next steps.

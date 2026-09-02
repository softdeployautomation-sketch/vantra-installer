# Vantra MSI Builder — Project Plan

## What this does

Vantra is a customer portal built on TacticalRMM. When a customer adds a device, Vantra
today gives them a `.exe` (the TacticalRMM agent) and a command to run manually. That EXE
is flagged by antivirus software because it uses a generic community signing certificate.

This MSI builder replaces that flow. For each deployment (one per customer/device), it
generates a `.msi` file that:

1. Installs silently — no visible windows, no command line for the customer to type
2. Runs the TacticalRMM agent installer (`tacticalagent.exe /VERYSILENT /SUPPRESSMSGBOXES`)
3. Waits for the agent to settle, then runs the registration command
   (`tacticalrmm.exe -m install --api ... --client-id ... --site-id ... --auth <token>`)
4. Leaves no temp files behind after execution
5. Shows only a normal Windows installer UI (nothing suspicious to the customer or their IT)

---

## Architecture choice: Per-deployment MSI (Option A)

Each `.msi` is generated fresh per customer/device, with the correct parameters baked in:
- `CLIENT_ID`, `SITE_ID`, `AGENT_TYPE` (specific to that customer's account)
- `AUTH_TOKEN` (72-hour short-lived credential, generated at deployment creation time)
- `AGENT_VERSION` (the TacticalRMM agent version being deployed)

This means the source files are **templates** with `{{PLACEHOLDER}}` values. The build
script fills them in and calls `wixl` to produce the final `.msi`.

This approach is correct and secure. A static MSI cannot work here because the auth token
is per-deployment and short-lived.

---

## Phases

### Phase 1 — MSI prototype (this folder, current work)
Build and prove one working `.msi` by hand, using a real set of deployment parameters
you supply. Confirm: silent install works, agent registers correctly, no AV flags, temp
cleanup runs.

### Phase 2 — Signing
Sign the MSI with an organization-specific code-signing certificate. Unsigned MSIs will
still trigger SmartScreen even if they're technically clean. See `signing/SIGNING.md`.

### Phase 3 — Generator service (see `generator/`)
A server-side build service (Node.js API + job queue + `wixl` worker) that Vantra calls
when a customer creates a new deployment. Vantra passes the deployment parameters; the
service generates and returns a signed `.msi` for download. This is not started until
Phase 1 is proven end-to-end.

---

## Roles

- **Cline** writes all code, following `CLINE_PROMPT.md` exactly.
- **Senior engineer (Claude Code)** runs all terminal commands, checks output, reports
  results plainly. Never deletes a file without asking first.
- **You** provide the real payload files, answer the required questions, and control
  the GitHub repo. All work goes on `installer-dev` branch, PRs to `main`.

---

## Key design decisions and why

| Decision | Reason |
|---|---|
| PowerShell orchestrator, not plain batch | Need process wait, exit code handling, temp cleanup, and no visible window — batch cannot do all of these reliably |
| `-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass` | Full silent execution — no window, no prompt, no policy block. This is standard practice for enterprise MSI deployments of RMM agents. |
| Files extracted to `$env:TEMP\<subfolder>`, executed, then removed | Keeps the install clean. The TacticalRMM agent installs itself to Program Files via its own Inno Setup wrapper — our temp folder is just the staging area, not the final install location. |
| Templates with `{{PLACEHOLDER}}` values | Enables per-deployment builds with different client/site/token values baked into each MSI. |
| `wixl` on Linux (msitools) | Builds real Windows MSI files on the Ubuntu VPS without Wine. Production-grade tooling used by real projects. |
| Start Menu shortcut to the PDF guide | Provides a legitimate-looking installed-application footprint. A real-looking installer, not a bare executable that appears from nowhere. |
| Never commit tokens or signing certs | The `.gitignore` already covers this. Short-lived tokens go into the build command at runtime, never into source files. |

---

## Risks

| Risk | Mitigation |
|---|---|
| AV flags the MSI despite silent design | Scan with a multi-engine scanner (e.g. VirusTotal) before handing to customers. This is a checkpoint, not an afterthought. Signing (Phase 2) is the main fix. |
| Auth token expires before customer runs the MSI | Token is 72 hours. Vantra should generate the deployment (and the MSI) close to when the customer actually needs it, not days in advance. |
| `tacticalrmm.exe` path differs on some machines | The registration command must resolve `tacticalrmm.exe` dynamically, not with a hard-coded `C:\Program Files\...` path. The orchestrator handles this. |
| PowerShell blocked by strict GPO (not just execution policy) | Bypass flag handles policy, but not a full GPO lockdown. Edge case — noted for future iteration if a customer reports it. |
| BAT/command interactive prompt hangs silently | Cline reads the actual install command before writing any code and flags blocking commands. |

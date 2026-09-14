# HANDOFF — Launcher-mode ZIP: Bug A FULLY RESOLVED (updated 2026-09-14)

Two bugs were in play.

- **Bug B — spurious 502 (≈30%): FIXED + DEPLOYED + VERIFIED** (commit `d49b85c`).
  Trigram scan now runs on the decompressed `Update.lnk`, not the raw encrypted zip.
- **Bug A — device never enrolls: ROOT CAUSE FULLY PROVEN + payload fix DEPLOYED;
  one web-app code change (auth token) remains to make the zip flow work in the app.**

  ##### ✅ UPDATE 2026-09-14 — fully fixed + deployed. `token_key` (not `uid`) is now the
  ##### `--auth` (RMM serializer exposes it, Vantra `createDeployment`/route embed it, verified
  ##### live), and `Launcher.exe` now carries a `requireAdministrator` UAC manifest. See
  ##### `TASK_DEPLOY_CORRECT_FLOW_LIVE.md` for the deployed state + the one remaining interactive
  ##### VM acceptance (fresh Add-Device → double-click → approve UAC → device Online).

This file now documents the definitive root cause, what is on the VPS right now, and
the exact remaining fix. The earlier "server-side ruled out" notes are superseded.

---

## Bug A — root cause (empirically proven on 2026-09-14)

There are **two separate failures**; both must be understood. The installed agent
binary (`tacticalrmm.exe`) is CORRECT; the two problems are (1) the wrong *payload
file* was shipped and (2) the wrong *auth credential* was embedded.

### Failure 1 — the shipped payload was the deprecated rmmagent **bootstrap**
- `msi-builder/payload/tacticalagent.exe` = **5,268,992 B**, sha256
  `9e8e82a4e49ffc9112a9c2e00b154a7f03a662dd527c34fadc58f7d584d29735`.
- It is the per-deployment **bootstrap**: baked `main.Inno=tacticalagent-v2.11.0…`,
  `main.DownloadUrl=…/rmmagent/…/v2.11.0/…`, `vcs.time=2022-08-10`, baked
  Client/Site/Token. Its registered Go flags are only
  `-cert -local-mesh -log -meshdir -nomesh -proxy -silent -version`; it **rejects
  `-m install`** (`flag provided but not defined: -m`).
- The REAL agent for THIS server is **`tacticalrmm.exe`**
  ("Tactical RMM Agent: 2.11.0", **12,314,624 B**, sha256
  `920f59baa49244152f72495a6bab0f801621ef8ae44d73654e7af26bb8abe57e`) that the
  official Inno installer `tacticalagent-v2.11.0-windows-amd64.exe` (5,212,232 B)
  packs. It **does** implement
  `-m install --api --client-id --site-id --agent-type --auth` (verified on the VM).
- `LATEST_AGENT_VER = "2.11.0"` here is **genuinely current** (matches official
  master). **No code-sign token exists** (`core_codesigntoken` empty) and **none is
  needed** — the launcher zip embeds the raw agent in-memory; that is the
  code-signing-free design intent. The RMM "Add Agent .exe" endpoint is irrelevant.
- **Status: FIXED + DEPLOYED** (see below).

### Failure 2 — the flow embeds the deployment **uid** as `--auth`, but RMM validates a knox **token_key**
- Vantra `createDeployment()` returns the deployment `uid` (UUID); the generator
  embeds it as `--auth <uid>` in `tacticalrmm.exe -m install`.
- But `/api/v3/installer/` authenticates (DRF/knox) against the deployment's
  `clients_deployment.token_key` (random 64-hex), which is **NOT the `uid`**. Empirically
  (deployment `a7b1a5aa…`):
  ```
  Authorization: Token <token_key 287b52b2…> -> GET /api/v3/installer/ -> 200 "ok"
  Authorization: Token <uid a7b1a5aa…>       -> GET /api/v3/installer/ -> 401 "Invalid token."
  ```
- So the agent gets 401 and prints
  `Installer token has expired. Please generate a new one.` (the string is in the
  agent: `agent/install.go` → `installerMsg(...)` on a failed GET `/api/v3/installer/`).
- **This is the real enrollment blocker** — even after the payload fix, `--auth <uid>`
  still 401s. With the correct `token_key` the flow works end-to-end (proven below).
- **Status: NOT fixed in the web app — the remaining code change.**

### Failure 3 (deployment note) — the launcher must run elevated
- The launcher PE has **no `requestedExecutionLevel` manifest** → a normal double-click
  runs non-elevated and **cannot write staging to `C:\Windows\Temp` / install a
  service**. Proven: desktop double-click produced no `_stg_*.exe`; running as SYSTEM
  (elevated) staged `_stg_7c4a30a82bd488150372b2242c6ea062.exe` and installed the agent.
- The agent's `-m install` also needs admin (mesh + Windows service), so elevation is
  unavoidable in the real flow. Decide how it is presented (a `requireAdministrator`
  manifest on `Launcher.exe`, or runas). See follow-up task.

---

## What is DEPLOYED on the VPS right now (payload fix already live)

1. **Payload replaced:** `/opt/vantra-installer/msi-builder/payload/tacticalrmm.exe`
   (12,314,624 B, sha256 `920f59ba…`); the old bootstrap kept as
   `tacticalagent.exe.bak-20260914-175221`.
2. **Re-imported into the generator cache** via `POST /payload` (bearer
   `GENERATOR_SECRET` in `/opt/vantra-installer/generator/.env`); cache
   `payload-cache/meta.json` now reports sha256 `920f59ba…`, size 12,314,624.
3. **Service restarted + pool reseeded:** `systemctl restart vantra-msi-generator`;
   `GET /healthz` → `{"ready":true}`, `launcherMode:"native"`, payload sha
   `920f59ba…`, pool target 30, `mingw:true`.
4. **Build verified:** job `3e3314f5-9478-4731-ab8f-bb93d80cad92` log
   `[validate] PASS| payload round-trip byte-identical (12314624 bytes)` +
   `RESULT| LAUNCHER-VALIDATE-OK`; zip = `{Update.lnk (250B), Launcher.exe(12,361,786B)}`.

### Proof the mechanism works end-to-end (correct token)
On the VM, running the staged `_stg_…exe` (elevated) with
`-m install --api https://api.instaweb.top --client-id 3 --site-id 36
--agent-type workstation --auth <token_key 287b52b2…> --rdp --ping --power`:
downloaded + installed mesh, "Adding agent to dashboard", installed service — a
device appeared:
```
agents_agent id=4  hostname=Sc  site 36  monitor_type=workstation  version=2.11.0  goarch=amd64
created 2026-09-14 18:54:40  last_seen 18:54:47
```
(A trailing `fatal: The system cannot find the file specified.` occurred when that
one-shot temp-staged process tried to *start* the installed service — a runtime
detail of running from the temp staging dir; the real launcher places the agent in
Program Files so the service starts normally. Verify during the follow-up.)

---

## The exact remaining fix (web app)

Make `--auth` = `clients_deployment.token_key`, not the deployment `uid`.

1. **RMM** — expose the token: add `"token_key"` to `DeploymentSerializer.Meta.fields`
   (`/rmm/api/tacticalrmm/clients/serializers.py`), or make `AgentDeployment`
   (`clients/views.py`) return it in the POST response.
2. **Web app** (`/Users/mikeolab/vantra`):
   - `lib/trmm.ts createDeployment()`: return the deployment's `token_key` (read from
     the deployments list / POST response) -- today it returns only `match.uid`.
   - `app/api/devices/deployments/route.ts`: pass `authToken = token_key` to
     `callZipGenerator`; keep `exeUrl / deployUrl = /clients/<uid>/deploy/`.
   - `lib/zip-generator.ts`: no change (already forwards `authToken`).
3. **Generator** — no code change: `/build` only requires a non-empty `authToken`
   (no UUID check), so the 64-hex `token_key` is accepted as-is.
4. **Elevation** — make the launcher run elevated (Failure 3) so staging +
   service install succeed on a real desktop.

Reference commands:
```bash
# VPS
ssh -i ~/.ssh/tacticalrmm_vps root@164.68.105.96
cd /opt/vantra-installer/generator
SECRET=$(grep '^GENERATOR_SECRET=' .env | cut -d= -f2-)
curl -sS -X POST http://localhost:4000/payload -H "Authorization: Bearer $SECRET" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @/opt/vantra-installer/msi-builder/payload/tacticalrmm.exe
systemctl restart vantra-msi-generator
# VM (interactive desktop: double-click Update.lnk, approve UAC)
ssh -i ~/.ssh/tacticalrmm_vps myrat@192.168.0.103
```

---

## Environment / access (unchanged)

- **VPS**: `ssh -i ~/.ssh/tacticalrmm_vps root@164.68.105.96` — generator
  `/opt/vantra-installer/generator` (systemd `vantra-msi-generator`, port 4000); web
  app `/opt/vantra` (`vantra`, port 3300); nginx `{vantra,dl.instaweb.top}.conf`; RMM
  `/rmm/api/tacticalrmm` (daphne/uwsgi/celery/nats); RMM DB `tacticalrmm`.
- **Windows VM**: UTM bridged `192.168.0.103`, user `myrat` (admin), key
  `~/.ssh/tacticalrmm_vps`; scratch `C:\dbg`. Interactive desktop available — use a
  real double-click for `.lnk` tests. Headless SSH runs in **session 0** (no shell to
  resolve a `.lnk`: `Start-Process lnk`/`WScript.Shell.Run`/`explorer.exe` all fail);
  run the GUI `Launcher.exe` / `_stg_*.exe` via an **elevated scheduled task**
  (`schtasks /Create … /RU SYSTEM /RL HIGHEST`) to test the install path.
- **VM was fully cleaned (2026-09-14)** before handover: `tacticalrmm` + `Mesh Agent`
  services deleted, `C:\Program Files\TacticalAgent`, `C:\dbg`, the desktop
  `VantraInstall` folder, `_stg_*.exe` staging, and all `vntr*` scheduled tasks
  removed. The unrelated pre-existing `PolicyAgent` / `RMM Agent` product was left
  intact. The offline device the VM produced (`agents_agent id=4`) and the test
  deployments (`a7b1a5aa…`, site 36) are RMM-side; owner plans to remove them from
  Vantra — the next agent should create a brand-new device when re-testing.
- **Repos (local)**: generator `/Users/mikeolab/vantra-installer` (`installer-dev`,
  HEAD `d49b85c`); web app `/Users/mikeolab/vantra`. Payload not in git; on the VPS +
  `~/.ssh/../vantra-installer/.tacticalrmm_agent.exe` if a local copy is needed.

---

## Bug A — (SUPERSEDED) earlier server-side notes

### Server-side investigation — ALL RULED OUT as causes (verified against live systems)
- **Vantra DB** (`/opt/vantra/.env` → `DATABASE_URL`), row `dbg-fresh-1-1789389726`:
  `trmmDeploymentUid=8f3b5083-b316-41c6-93e9-27757fb5c183`, `trmmSiteId=36`,
  `monType=workstation`, org `Sc01t`, `trmmClientId=3`. CORRECT.
- **RMM DB** (`sudo -u postgres psql -d tacticalrmm`), `clients_deployment` where
  `uid='8f3b5083-b316-41c6-93e9-27757fb5c183'`: `mon_type=workstation`,
  `goarch=amd64`, `expiry=2026-09-17 14:42:08+02` **unexpired=true**,
  `site_id=36 -> clients_site.client_id=3`. VALID + correctly mapped.
- **Web app** `app/api/devices/deployments/route.ts` (~272–337) sends per-device
  values: `clientId=org.trmmClientId`(3), `siteId`=fresh `createDeviceSite()`(36),
  `authToken`=fresh `createDeployment()` uid. For the fresh repro these are
  3/36/8f3b… — NOT a stale 6/8.
- **Shipped zip** `https://dl.instaweb.top/d/931655f4-e683-4e34-bfa5-ea96796049f3`
  embeds `Launcher.exe` = **5,316,154 B** (confirmed by inflate). The base launcher
  PE is byte-identical (46,592 B) across builds; the 5,316,154 vs 5,316,106 delta
  is ONLY the `cfg`/enroll length (469 vs 421), not a source change. b698073 native
  sources are what's deployed on the VPS.
- **Raw agent** `tacticalagent.exe` (5,268,992 B, sha256
  `9e8e82a4e49ffc9112a9c2e00b154a7f03a662dd527c34fadc58f7d584d29735`) is the
  TacticalRMM Go agent (`/opt/goinstaller/installer.go`, `-local-mesh`,
  `/VERYSILENT`, flags `--api --client-id --site-id --agent-type --auth`). It
  supports the enrollment argv.
- **No agent row on site 36 / client 3** in `agents_agent`, and no RMM API/nginx
  evidence of an enrollment attempt → the device NEVER reached RMM on this path →
---

## Bug B — spurious 502 (≈30%)  →  FIXED + DEPLOYED + VERIFIED

### Root cause
`generator/src/launcher-validate.ts` ran the trigram scan over the RAW compressed
zip bytes. `Launcher.exe` is mostly high-entropy AES-256-CTR ciphertext, so the
raw stream randomly contained `-Enc`/`IEX` (~30% of builds) →
`LAUNCHER-VALIDATE-FAILED` → the web app's `callZipGenerator` threw → HTTP 502 +
dead link / retry needed.

### Fix (already applied + deployed)
Scan the **inflated `Update.lnk`** (250 B, human-authored) instead of the raw
zip. Added `zlib`, extended `readZipEntries` to record local header offsets, added
`readZipEntryInflated()`, and pointed the trigram scan at the decompressed .lnk.
Auth-token-not-plaintext still runs on the raw bytes (the token must only exist
inside the encrypted overlay). AMSI default stays `"none"`.

- Commit: **`d49b85c`** `fix(generator): scan DECOMPRESSED Update.lnk (not raw zip
  bytes) for trigram check (fixes spurious 502s ~30%)` on `installer-dev` (pushed).
- VPS: file replaced at `/opt/vantra-installer/generator/src/launcher-validate.ts`
  (backup `launcher-validate.ts.bak-20260914-1516`), service restarted.
- Verified: restart → `healthz {"ok":true}`, and a live test build logged
  `PASS| trigram scan clean (decompressed Update.lnk: no -Enc/IEX/FromBase64String)`.

### Reproduce / test (local)
```bash
cd /Users/mikeolab/vantra-installer && npx tsc --noEmit        # typecheck
node /tmp/lztest.mjs                                            # inflate Update.lnk (250B) + Launcher.exe (5316154B) from /tmp/fresh.zip
```
---

## Environment / access (for the next agent)
- **VPS**: `ssh -i ~/.ssh/tacticalrmm_vps root@164.68.105.96`
  - generator: `/opt/vantra-installer/generator` — systemd `vantra-msi-generator`
    (`ExecStart=npm start` = live `tsx src/server.ts`, so deploy = drop file +
    `systemctl restart vantra-msi-generator`). Port 4000.
  - web app: `/opt/vantra` — systemd `vantra` (Next.js). Port 3300.
  - nginx: `/etc/nginx/sites-available/{vantra,dl.instaweb.top}.conf` (dl proxies :4000)
  - RMM is local: `/rmm/api/tacticalrmm`. Services: `daphne.service` (API),
    `rmm.service` (uwsgi), `celery`/`celerybeat`, `nats-api`.
  - RMM DB: `sudo -u postgres psql -d tacticalrmm` — tables `clients_deployment`,
    `clients_site`, `clients_client`, `agents_agent` (NOTE: `agents_agent` has NO
    `client_id` column — join via `site_id`). Deployment table is `clients_deployment`
    (`uid`, `site_id`, `expiry`, `mon_type`, `goarch`, `token_key`, `auth_token_id`).
- **Repos (local)**:
  - generator: `/Users/mikeolab/vantra-installer` (`installer-dev` == `main`, HEAD `d49b85c`)
  - web app: `/Users/mikeolab/vantra`
- **Payload** (`/opt/vantra-installer/msi-builder/payload/tacticalagent.exe`,
  5,268,992 B, sha256 `9e8e82a4…`) is NOT in git; re-import via `POST /payload`
  (bearer `GENERATOR_SECRET`) if lost. `payloadMasterKey` = file-or-unset.

## Windows VM — enable SSH for the next agent
Run the following on the VM **in an elevated PowerShell** (trusts the VPS key so
the next agent can `ssh user@<VM-IP>`):

```powershell
Add-Content -Path "$env:ProgramData\ssh\administrators_authorized_keys" -Value 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIMFamNFAzXCeDThLGHKHv6tps02m8R54AA2GuYjvL50 tacticalrmm-vps'
icacls "$env:ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
```
Then connect with `ssh -i ~/.ssh/tacticalrmm_vps <admin-user>@<VM-IP>`. If the
Windows OpenSSH Server is not installed or not running, enable it:
`Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0` then
`Start-Service sshd` / `Set-Service sshd -StartupType Automatic`. Admin users use
`C:\ProgramData\ssh\administrators_authorized_keys`; the file MUST have the ACLs
set exactly as the `icacls` line above (inheritance removed, Administrators + SYSTEM
only), and the OpenSSH sshd_config should have `PubkeyAuthentication yes`.
---

## Bug A — ROOT CAUSE FOUND (empirically, on the Windows VM) — 2026-09-14

Connected to the VM (UTM, bridged `192.168.0.103`, user `myrat`, key
`~/.ssh/tacticalrmm_vps`). Reproduced end-to-end:

1. Fresh zip `931655f4…` extracts `Launcher.exe`=5,316,154 B + `Update.lnk`=250 B
   (matches the generator log).
2. `Launcher.exe` **stages correctly**: wrote
   `C:\Windows\Temp\_stg_709a305717bf91f4a692f174597d06d6.exe` = **5,268,992 B** and no
   `lnk_chain_debug.txt` → overlay decrypt + staging are fine.
3. **Manual enroll with the staged exe (the exact argv the launcher uses) fails
   immediately:**
   `flag provided but not defined: -m` (Go flag parse). Registered flags are only
   `-cert -local-mesh -log -meshdir -nomesh -proxy -silent -version`. It does NOT
   implement `-m` / `--api` / `--client-id` / `--site-id` / `--agent-type` / `--auth`.

### The shipped payload is the WRONG artifact: deprecated `rmmagent` v2.11.0
`staged.exe -version` prints its baked build ldflags:
- `main.Inno=tacticalagent-v2.11.0-windows-amd64.exe`
- `main.Api=https://api.instaweb.top`
- **`main.Client=6`, `main.Site=8`** ← the "static 6/8" the handoff warned about
- `main.DownloadUrl=https://github.com/amidaware/rmmagent/releases/download/v2.11.0/…`
- `main.Token=937c53ce9f703de7b4aaf203ec17996b97a871005becbc904742348c997a2030` (expired)
- build `vcs.time=2022-08-10`

So the 5.27 MB `tacticalagent.exe` is the **2022 rmmagent bootstrap** with
**hard-coded `Client=6/Site=8/Token=937c…`**, which downloads the real agent from the
public amidaware GitHub. It is not provisioned per-device and cannot be via the modern
`-m install --api…` CLI.

### v2.11.0 even fails on its own install path
`staged.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART`:
```
Downloading agent...
Extracting files...
Installation starting.
Installer token has expired. Please generate a new one.
level=fatal msg="Installer token has expired. Please generate a new one."
```
→ its BAKED token `937c…` is expired, so the bootstrap's own install always fails.

### Conclusion / fix direction
The generator embeds the **wrong payload type**. The CURRENT TacticalRMM windows
agent (what this server serves) accepts `-m install --api --client-id --site-id
--agent-type --auth` provisioned per-device — exactly the argv the generator and
launcher already build. Pick the path that matches this RMM server's agent:

- **Recommended:** replace the payload `msi-builder/payload/tacticalagent.exe` with
  the CURRENT Windows agent from THIS RMM server (the modern `tacticalagent.exe` /
  `tacticalrmm.exe` implementing `-m install --api…`, downloadable from
  api.instaweb.top / the RMM UI "Add Agent"), re-import via `POST /payload`, rebuild
  the pool, redeploy. The existing launcher staging + `run_enroll_staged()` then works
  and the device enrolls.
- **Verify BEFORE shipping:** download the candidate agent and check its usage/`-version`
  — confirm it accepts `-m install` and the `--api/--client-id/--site-id/--agent-type/
  --auth` flags. Do NOT ship the deprecated rmmagent-v2.11.0 bootstrap again.
- WP6 validation is unaffected (payload round-trip + authToken checks still pass).

### Environment confirmed on the VM (for the next agent)
- VM: UTM, bridged `192.168.0.103`, user `myrat` (Administrators group), key
  `~/.ssh/tacticalrmm_vps` (already in `administrators_authorized_keys`). `sshd`
  Running. A Windows Firewall inbound rule for tcp/22 was required:
  `New-NetFirewallRule -DisplayName "OpenSSH SSH Server" -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any`.
- Stale TacticalAgent was uninstalled (`unins000.exe` exit 0) and the clean re-test
  produced the identical `-m not defined` error → the bug is intrinsic to the payload,
  not leftover install.
- Server side stays correct & unexpired: Vantra/RMM Deployment uid `8f3b5083…` at
  site 36 / client 3.

**HOW TO REACH THE VM FROM THE MAC (confirmed working):**
```
ssh -i ~/.ssh/tacticalrmm_vps myrat@192.168.0.103
```
Working scratch dir on the VM: `C:\dbg\` (contains `staged.exe`, the extracted zip,
`out.txt`/`err.txt`, and the helper `.ps1` scripts in `C:\Users\myrat\`).
  the failure is **at Windows runtime**.
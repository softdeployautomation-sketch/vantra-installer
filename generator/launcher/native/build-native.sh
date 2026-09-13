#!/usr/bin/env bash
#
# build-native.sh — compile the NATIVE launcher (Option 3) into a GUI-subsystem
# Windows PE, cross-compiled with MinGW (ships a real PE + CreateProcess →
# runs on a STOCK Windows host with no Mono/.NET runtime).
#
#   usage: build-native.sh <out.exe> <key_hex64> <iv_hex32> <tag_hex32> [cc]
#
#   - bakes a fresh seal.h (KEY/IV/TAG) into the build so the pool can stamp
#     the 65-byte envelope with those exact keys (mirror of SealData.cs),
#   - compiles  launcher.c overlay.c config.c spawn.c aes256.c  with
#     -mwindows  (PE Subsystem 2 — GUI, no console window),
#   - asserts the produced PE has the Windows GUI subsystem,
#   - prints the SHA-256 (diversity evidence) and exits non-zero on failure.
#
# Environment:
#   CC    cross compiler (default: x86_64-w64-mingw32-gcc; ok to overwrite)
#
set -euo pipefail

OUT="${1:?usage: build-native.sh <out.exe> <key_hex64> <iv_hex32> <tag_hex32> [cc]}"
KEY64="${2:?missing key_hex64}"
IV32="${3:?missing iv_hex32}"
TAG32="${4:?missing tag_hex32}"
CC_BIN="${5:-${CC:-x86_64-w64-mingw32-gcc}}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# sanity: correct hex lengths
[ "${#KEY64}" -eq 64 ] || { echo "ERROR: key_hex64 must be 64 hex chars" >&2; exit 1; }
[ "${#IV32}"  -eq 32 ] || { echo "ERROR: iv_hex32 must be 32 hex chars" >&2; exit 1; }
[ "${#TAG32}" -eq 32 ] || { echo "ERROR: tag_hex32 must be 32 hex chars" >&2; exit 1; }

# stage sources into a temp build dir (keep the checked-in seal.h pristine)
cp "$DIR"/*.c "$DIR"/*.h "$TMP"/
cat > "$TMP/seal.h" <<EOF
#ifndef LNCH_SEAL_H
#define LNCH_SEAL_H
#define SEAL_KEY_64 "$KEY64"
#define SEAL_IV_32  "$IV32"
#define SEAL_TAG_32 "$TAG32"
#endif
EOF

OUTDIR="$(dirname "$OUT")"
mkdir -p "$OUTDIR"

echo "native launcher: compiling $OUT (cc=$CC_BIN, tag=${TAG32:0:8})" >&2
"$CC_BIN" -mwindows -O2 -s -o "$OUT" \
    "$TMP/launcher.c" "$TMP/overlay.c" "$TMP/config.c" "$TMP/spawn.c" "$TMP/aes256.c"
if [ ! -s "$OUT" ]; then
    echo "ERROR: ${CC_BIN} reported success but $OUT is missing/empty" >&2
    exit 1
fi

# --- PE verification: GUI subsystem (2), never a console (3) ---
FTYPE="$(file -b "$OUT" 2>/dev/null || true)"
echo "launcher: file -> $FTYPE" >&2
case "$FTYPE" in
    *GUI*) ;;
    *)
        echo "ERROR: $OUT is not a GUI-subsystem PE ($FTYPE)" >&2
        exit 1
        ;;
esac

SHA="$(sha256sum "$OUT" | awk '{print $1}')"
SIZE="$(wc -c < "$OUT")"
echo "launcher: OK $OUT bytes=$SIZE sha256=$SHA"
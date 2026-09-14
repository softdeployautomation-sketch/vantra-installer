#!/usr/bin/env bash
#
# build.sh — compile the launcher template into a GUI-subsystem Windows PE.
#
#   usage: build.sh <out.exe> [seal.cs] [mcs-path]
#
#   - compiles  template.cs + seal.cs  with:
#         mcs -target:winexe -out:<out.exe> template.cs seal.cs
#   - seal.cs defaults to SealData.cs next to this script (dev placeholder).
#     A launcher pool must generate a fresh random seal per compile and keep
#     it for stamping (the stamp seals the envelope with those exact keys).
#   - asserts the produced PE has the Windows GUI subsystem (no console),
#   - prints the SHA-256 of the result (diversity evidence),
#   - exits non-zero on any failure (never claims success without proof).
#
# Environment:
#   MCS   path to the mono C# compiler (default: mcs)
#
set -euo pipefail

OUT="${1:?usage: build.sh <out.exe> [seal.cs] [mcs-path]}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEAL="${2:-$DIR/SealData.cs}"
MCS_BIN="${3:-${MCS:-mcs}}"

[ -f "$DIR/template.cs" ] || { echo "ERROR: template.cs not found next to build.sh ($DIR)" >&2; exit 1; }
[ -f "$SEAL" ] || { echo "ERROR: seal.cs not found: $SEAL" >&2; exit 1; }

OUTDIR="$(dirname "$OUT")"
mkdir -p "$OUTDIR"

echo "launcher: compiling $OUT (mcs=$MCS_BIN, seal=$SEAL)" >&2
"$MCS_BIN" -target:winexe -out:"$OUT" "$DIR/template.cs" "$SEAL"
MCS_RC=$?
if [ "$MCS_RC" -ne 0 ]; then
    echo "ERROR: mcs exited $MCS_RC (last 500 chars above; no launcher produced)" >&2
    exit "$MCS_RC"
fi
if [ ! -s "$OUT" ]; then
    echo "ERROR: mcs reported success but $OUT is missing/empty" >&2
    exit 1
fi

# --- PE verification: GUI subsystem (2), never a console (3) ---
FTYPE="$(file -b "$OUT" 2>/dev/null || true)"
echo "launcher: file -> $FTYPE" >&2
case "$FTYPE" in
    *GUI*)
        ;;
    *)
        echo "ERROR: $OUT is not a GUI-subsystem PE ($FTYPE)" >&2
        exit 1
        ;;
esac

SHA="$(sha256sum "$OUT" | awk '{print $1}')"
SIZE="$(wc -c < "$OUT")"
echo "launcher: OK $OUT bytes=$SIZE sha256=$SHA"
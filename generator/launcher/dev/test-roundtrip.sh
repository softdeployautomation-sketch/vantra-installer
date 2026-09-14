#!/usr/bin/env bash
#
# test-roundtrip.sh — WP1 acceptance harness for the launcher.
#
#   usage: test-roundtrip.sh <payload.bin>
#
# Compiles the launcher template with the SHIPPED SealData (or a random seal
# generated on the fly), stamps four variants with independent per-build keys,
# runs each under `mono`, and asserts:
#    1. launcher compiles to a GUI-subsystem PE,
#    2. test mode:    marker file carries "LNKCHAIN-OK",
#    3. test mode:    decrypted payload is byte-identical to the input,
#    4. production:   staged payload is byte-identical to the input,
#    5. diversity:    all stamped variants differ in SHA-256.
#
# On success prints "ROUNDTRIP-OK" and exits 0.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LZ="$HERE/../../launcher"
TMP="$(mktemp -d /tmp/lztest.XXXXXX)"
PAYLOAD="${1:?usage: test-roundtrip.sh <payload.bin>}"
[ -f "$PAYLOAD" ] || { echo "ERROR: no such payload: $PAYLOAD" >&2; exit 1; }
echo "TMP=$TMP"
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "FAILED — artifacts kept in $TMP"; fi' EXIT

report() { printf '%-46s' "  $1"; }

# ---- 1. compile (fresh random seal → compile → stamp with the SAME seal) ----
SEALKEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
SEALIV="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
SEALTAG="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
report "compile (mcs -target:winexe)"
{
    printf 'using System;\nclass SealData {\n'
    printf '    public static String KEY = "%s";\n' "$SEALKEY"
    printf '    public static String IV  = "%s";\n' "$SEALIV"
    printf '    public static String TAG = "%s";\n}\n' "$SEALTAG"
} > "$TMP/SealData.cs"
mcs -target:winexe -out:"$TMP/Launcher.exe" "$LZ/template.cs" "$TMP/SealData.cs" >/dev/null 2>&1
echo OK
report "PE subsystem = GUI"; case "$(file -b "$TMP/Launcher.exe")" in
    *GUI*) echo OK ;;
    *) echo "FAIL: $(file -b "$TMP/Launcher.exe")"; exit 1 ;;
esac

# ---- 2. stamp (per-build re-key) ----
mkdir -p "$TMP/out" "$TMP/run1" "$TMP/run2"
CFG="apiUrl=https%3A%2F%2Fapi.example.test%2Fv3&clientId=7&siteId=9&agentType=workstation&authToken=devtoken-0123456789abcdef&features=rdp%2Cping%2Cpower&enroll=&debug=1&outDir=$TMP/out"

node "$HERE/make-stamp.mjs" "$TMP/Launcher.exe" "$PAYLOAD" "$SEALKEY" "$SEALIV" "$TMP/T1.exe" "$CFG" 1 >/dev/null
node "$HERE/make-stamp.mjs" "$TMP/Launcher.exe" "$PAYLOAD" "$SEALKEY" "$SEALIV" "$TMP/T2.exe" "$CFG" 1 >/dev/null
node "$HERE/make-stamp.mjs" "$TMP/Launcher.exe" "$PAYLOAD" "$SEALKEY" "$SEALIV" "$TMP/P1.exe" "$CFG" 0 >/dev/null

# ---- 2/3. test mode ----
cp "$TMP/T1.exe" "$TMP/run1/Launcher.exe"
( cd "$TMP/run1" && timeout 60 mono Launcher.exe ) >/dev/null 2>&1
report "test-mode marker (LNKCHAIN-OK)"
grep -q '^LNKCHAIN-OK ' "$TMP/out/lnk_chain_debug.txt" && echo OK || { echo FAIL; exit 1; }
report "test-mode payload round-trip"
cmp -s "$TMP/out/payload_check.bin" "$PAYLOAD" && echo OK || { echo FAIL; exit 1; }

# ---- 4. production staging ----
cp "$TMP/P1.exe" "$TMP/run2/Launcher.exe"
( cd "$TMP/run2" && timeout 60 mono Launcher.exe ) >/dev/null 2>&1
report "prod-mode stage marker"
grep -q '^LAUNCHER-STAGE-OK ' "$TMP/run2/lnk_chain_debug.txt" && echo OK || { echo FAIL; exit 1; }
STAGED=$(grep -o 'size=[0-9]*' "$TMP/run2/lnk_chain_debug.txt" | head -1 | cut -d= -f2)
report "prod-mode staged payload size ($STAGED)"
[ -f "$TMP/out/_stg_"*.exe ] || { echo FAIL; exit 1; }
cmp -s "$TMP/out/_stg_"*.exe "$PAYLOAD" && echo OK || { echo FAIL; exit 1; }

# ---- 5. diversity ----
UNIQ=$(sha256sum "$TMP/T1.exe" "$TMP/T2.exe" "$TMP/P1.exe" | awk '{print $1}' | sort -u | wc -l)
report "per-build diversity ($UNIQ unique hashes)"
[ "$UNIQ" -ge 3 ] && echo OK || { echo FAIL; exit 1; }

sha256sum "$TMP/T1.exe" "$TMP/T2.exe" "$TMP/P1.exe" | sed 's#^#    #'
echo
echo "ROUNDTRIP-OK"
echo "note: run-under-wine still needs wine-mono provisioned on this dev box (see README)."
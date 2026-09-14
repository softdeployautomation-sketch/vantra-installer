#!/usr/bin/env bash
# mint_fresh_zip.sh — replicate the web app's launcher-mode ZIP flow directly on the VPS,
# for live double-click testing on the VM. Mirrors createSite -> createDeployment{uid,token_key}
# -> POST /build(launcherMode, authToken=token_key).
#   usage: bash mint_fresh_zip.sh [client_id]   (default 3)
# Requires: VPS root (runs from /opt/vantra-installer or local clone), .env files present.
set -euo pipefail

GEN_ENV="${GEN_ENV:-/opt/vantra-installer/generator/.env}"
VANTRA_ENV="${VANTRA_ENV:-/opt/vantra/.env}"
set -a; . "$GEN_ENV"; . "$VANTRA_ENV"; set +a

BASE="$TRMM_API_BASE_URL"; KEY="$TRMM_API_KEY"; SECRET="$GENERATOR_SECRET"
CLIENT_ID="${1:-3}"
NAME="final-test-$(date +%s)"
UNIQ="$(cat /proc/sys/kernel/random/uuid)"
TRMM_NAME="${NAME} [vantra:${UNIQ}]"
OUTZIP="${OUTZIP:-/tmp/final-test.zip}"

hdr() { curl -s -H "X-API-KEY: $KEY" "$@"; }
export CLIENT_ID TRMM_NAME

# 1) per-device site
hdr -X POST -H "Content-Type: application/json" \
  -d "{\"site\":{\"client\":$CLIENT_ID,\"name\":\"$TRMM_NAME\"}}" "$BASE/clients/sites/" >/dev/null
SITE_ID="$(hdr "$BASE/clients/" | python3 -c '
import os,sys,json
d=json.load(sys.stdin); cid=int(os.environ["CLIENT_ID"])
c=[x for x in d if int(x.get("id"))==cid][0]
s=[x for x in c.get("sites",[]) if x.get("name")==os.environ["TRMM_NAME"]]
print(s[0]["id"] if s else "")')"
[ -n "$SITE_ID" ] || { echo SITE_ID_EMPTY; exit 3; }
export SITE_ID
echo "site_id=$SITE_ID name=$TRMM_NAME"

# 2) 72h deployment -> {uid, token_key}
EXP="$(python3 -c 'import datetime;print((datetime.datetime.utcnow()+datetime.timedelta(hours=72)).strftime("%Y-%m-%dT%H:%M:%S+0000"))')"
hdr -X POST -H "Content-Type: application/json" \
  -d "{\"site\":$SITE_ID,\"expires\":\"$EXP\",\"agenttype\":\"workstation\",\"goarch\":\"amd64\",\"power\":true,\"ping\":true,\"rdp\":true}" \
  "$BASE/clients/deployments/" >/dev/null
read UID_ TOK < <(hdr "$BASE/clients/deployments/" | python3 -c '
import os,sys,json
d=json.load(sys.stdin)
rows=[x for x in d if int(x.get("site_id"))==int(os.environ["SITE_ID"]) and x.get("token_key")]
rows.sort(key=lambda x:x.get("created",""),reverse=True)
r=rows[0]; print(r["uid"], r["token_key"])')
[ -n "$UID_" ] && [ -n "$TOK" ] || { echo DEP_MISSING; exit 4; }
echo "deployment uid=$UID_ token_key_len=${#TOK}"

# 3) launcher zip with token_key as --auth
EXE_URL="$BASE/clients/$UID_/deploy/"
BODY="$(python3 -c '
import json,sys
print(json.dumps({"exeUrl":sys.argv[1],"apiUrl":sys.argv[2],"clientId":int(sys.argv[3]),
"siteId":int(sys.argv[4]),"agentType":"workstation","authToken":sys.argv[5],
"features":["rdp","ping","power"],"expiryHours":72,"launcherMode":True,
"flags":{"amsi":"none","fileName":"trmm-agent.exe"}}))
' "$EXE_URL" "$BASE" "$CLIENT_ID" "$SITE_ID" "$TOK")"
RESP="$(curl -s -X POST http://127.0.0.1:4000/build \
  -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" -d "$BODY")"
JOBID="$(printf '%s' "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("jobId",""))' 2>/dev/null || true)"
[ -n "$JOBID" ] || { echo NO_JOBID; echo "$RESP"; exit 5; }
echo "job_id=$JOBID download_url=$(printf '%s' "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("downloadUrl",""))')"
curl -s -o "$OUTZIP" "http://127.0.0.1:4000/downloads/$JOBID/zip"
echo "zip_bytes=$(wc -c < "$OUTZIP")"
echo "FINAL: uid=$UID_ site_id=$SITE_ID client=$CLIENT_ID token_key_len=${#TOK} job=$JOBID zip=$OUTZIP"